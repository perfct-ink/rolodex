import Contacts
import Combine
import Foundation

enum SidebarSelection: Hashable {
    case allContacts
    case group(String)
    case smartGroup(UUID)
    case insights
}

@MainActor
final class ContactsViewModel: ObservableObject {
    @Published var contacts: [CNContact] = []
    @Published var groups: [CNGroup] = []
    @Published var membership: [String: Set<String>] = [:]
    @Published var smartGroups: [SmartGroup] = []
    @Published var hiddenGroupIdentifiers: Set<String> = []
    @Published var blockedContactIdentifiers: Set<String> = []
    @Published var selection: SidebarSelection = .allContacts
    @Published var searchText: String = ""
    @Published var selectedContactIDs: Set<String> = []
    @Published var authorizationDenied = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var contactsByID: [String: CNContact] = [:]
    private(set) var membersByGroup: [String: Set<String>] = [:]
    private var searchTextByID: [String: [String]] = [:]
    private var refreshRequested = false
    private var scheduledRefresh: Task<Void, Never>?
    private var didStart = false
    private let loadSnapshot: @MainActor () async throws -> ContactsSnapshot

    private let contactsService = ContactsService.shared
    private let dataStore = AppDataStore.shared
    let history = ContactHistoryStore.shared
    private var notificationObserver: NSObjectProtocol?

    init(loadSnapshot: (@MainActor () async throws -> ContactsSnapshot)? = nil) {
        self.loadSnapshot = loadSnapshot ?? {
            try await ContactsService.shared.fetchSnapshot()
        }
        smartGroups = dataStore.data.smartGroups
        hiddenGroupIdentifiers = dataStore.data.hiddenGroupIdentifiers
        blockedContactIdentifiers = dataStore.data.blockedContactIdentifiers
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        let granted = await contactsService.requestAccess()
        authorizationDenied = !granted
        guard granted else { return }
        await refreshAll()
    }

    private func scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self else { return }
            await self.refreshAll()
        }
    }

    func refreshAll() async {
        guard !isLoading else {
            refreshRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshRequested = false
            do {
                let snapshot = try await loadSnapshot()
                contactsByID = snapshot.contactsByID
                membersByGroup = snapshot.membersByGroup
                searchTextByID = snapshot.searchTextByID
                membership = snapshot.membership
                groups = snapshot.groups
                contacts = snapshot.contacts
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        } while refreshRequested
    }

    // MARK: - Derived data

    func smartGroup(withID id: UUID) -> SmartGroup? {
        SmartGroup.builtIns.first { $0.id == id } ?? smartGroups.first { $0.id == id }
    }

    var visibleContacts: [CNContact] {
        var base: [CNContact]
        switch selection {
        case .allContacts:
            let hiddenSmartGroups = smartGroups.filter { $0.isHiddenFromAllContacts }
            let hiddenBySmartGroup = Set(hiddenSmartGroups.flatMap { evaluate(smartGroup: $0).map(\.identifier) })
            base = contacts.filter { contact in
                let groupIDs = membership[contact.identifier] ?? []
                guard groupIDs.isDisjoint(with: hiddenGroupIdentifiers) else { return false }
                return !hiddenBySmartGroup.contains(contact.identifier)
            }
        case .group(let identifier):
            base = contacts.filter { membership[$0.identifier]?.contains(identifier) == true }
        case .smartGroup(let id):
            guard let smartGroup = smartGroup(withID: id) else { return [] }
            base = evaluate(smartGroup: smartGroup)
        case .insights:
            base = []
        }

        guard !searchText.isEmpty else { return base }
        let needle = searchText.lowercased()
        return base.filter { searchTextByID[$0.identifier]?.contains(where: { $0.contains(needle) }) == true }
    }

    func evaluate(smartGroup: SmartGroup) -> [CNContact] {
        guard !smartGroup.rules.isEmpty else { return [] }
        return contacts.filter { contact in
            let groupIDs = membership[contact.identifier] ?? []
            let results = smartGroup.rules.map { rule in
                contact.matches(field: rule.field, operator: rule.op, value: rule.value, groupIdentifiers: groupIDs)
            }
            switch smartGroup.matchType {
            case .all: return results.allSatisfy { $0 }
            case .any: return results.contains(true)
            }
        }
    }

    // MARK: - Group management

    func isGroupHidden(_ identifier: String) -> Bool {
        hiddenGroupIdentifiers.contains(identifier)
    }

    func toggleGroupHidden(_ identifier: String) {
        if hiddenGroupIdentifiers.contains(identifier) {
            hiddenGroupIdentifiers.remove(identifier)
        } else {
            hiddenGroupIdentifiers.insert(identifier)
        }
        dataStore.update { $0.hiddenGroupIdentifiers = self.hiddenGroupIdentifiers }
    }

    func isContactBlocked(_ identifier: String) -> Bool {
        blockedContactIdentifiers.contains(identifier)
    }

    func toggleBlocked(_ identifier: String) {
        if blockedContactIdentifiers.contains(identifier) {
            blockedContactIdentifiers.remove(identifier)
        } else {
            blockedContactIdentifiers.insert(identifier)
        }
        dataStore.update { $0.blockedContactIdentifiers = self.blockedContactIdentifiers }
    }

    private func performChange(_ operation: @escaping (ContactsService) async throws -> Void) {
        Task {
            do {
                try await operation(contactsService)
                scheduleRefresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createGroup(named name: String) {
        performChange { service in
            try await service.createGroup(named: name)
        }
    }

    func rename(group: CNGroup, to newName: String) {
        performChange { service in
            try await service.rename(group: group, to: newName)
        }
    }

    func delete(group: CNGroup) {
        performChange { service in
            try await service.delete(group: group)
            if self.selection == .group(group.identifier) {
                self.selection = .allContacts
            }
        }
    }

    func merge(source: CNGroup, into destination: CNGroup) {
        performChange { service in
            try await service.mergeGroup(source, into: destination)
            if self.selection == .group(source.identifier) {
                self.selection = .group(destination.identifier)
            }
        }
    }

    func membershipState(for contactIDs: Set<String>, in groupIdentifier: String) -> Bool? {
        guard !contactIDs.isEmpty else { return false }
        let states = contactIDs.map { membership[$0]?.contains(groupIdentifier) == true }
        if states.allSatisfy({ $0 }) { return true }
        if states.allSatisfy({ !$0 }) { return false }
        return nil
    }

    func setMembership(_ isMember: Bool, contactIDs: Set<String>, group: CNGroup) {
        let targetContacts = contactIDs.compactMap { contactsByID[$0] }
        guard !targetContacts.isEmpty else { return }
        performChange { service in
            if isMember {
                try await service.addContacts(targetContacts, to: group)
            } else {
                try await service.removeContacts(targetContacts, from: group)
            }
        }
    }

    func deleteSelectedContacts() {
        let targetIDs = selectedContactIDs
        let targets = targetIDs.compactMap { contactsByID[$0] }
        guard !targets.isEmpty else { return }
        performChange { service in
            try await service.delete(targets)
            self.selectedContactIDs.subtract(targetIDs)
        }
    }

    /// Returns whether the edit was saved; on failure the error alert is shown.
    func saveContact(identifier: String, from baseline: ContactDraft, to draft: ContactDraft) async -> Bool {
        let changes = baseline.changes(to: draft)
        guard !changes.isEmpty else { return true }
        do {
            try await contactsService.updateContact(identifier: identifier) { contact in
                draft.apply(to: contact, baseline: baseline)
            }
            history.record(changes, contactID: identifier)
            scheduleRefresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createContact(_ mutable: CNMutableContact, groups: [CNGroup]) {
        performChange { service in
            try await service.createContact(mutable, in: groups)
        }
    }

    // MARK: - Smart groups

    func upsert(smartGroup: SmartGroup) {
        if let index = smartGroups.firstIndex(where: { $0.id == smartGroup.id }) {
            smartGroups[index] = smartGroup
        } else {
            smartGroups.append(smartGroup)
        }
        dataStore.update { $0.smartGroups = self.smartGroups }
    }

    func deleteSmartGroup(_ smartGroup: SmartGroup) {
        smartGroups.removeAll { $0.id == smartGroup.id }
        if selection == .smartGroup(smartGroup.id) {
            selection = .allContacts
        }
        dataStore.update { $0.smartGroups = self.smartGroups }
    }

    // MARK: - Insights

    struct GroupStat: Identifiable {
        var id: String { identifier }
        let identifier: String
        let name: String
        let count: Int
    }

    struct OverlapPair: Identifiable {
        var id: String { "\(first)-\(second)" }
        let first: String
        let second: String
        let firstName: String
        let secondName: String
        let overlapCount: Int
        let overlapFraction: Double
    }

    var groupStats: [GroupStat] {
        groups.map { group in
            let count = membersByGroup[group.identifier]?.count ?? 0
            return GroupStat(identifier: group.identifier, name: group.name, count: count)
        }
        .sorted { $0.count > $1.count }
    }

    var emptyGroups: [CNGroup] {
        groups.filter { group in
            (membersByGroup[group.identifier] ?? []).isEmpty
        }
    }

    var contactsWithoutGroup: [CNContact] {
        contacts.filter { (membership[$0.identifier] ?? []).isEmpty }
    }

    var overlappingGroupPairs: [OverlapPair] {
        var results: [OverlapPair] = []
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count {
                let a = groups[i]
                let b = groups[j]
                let membersA = membersByGroup[a.identifier] ?? []
                let membersB = membersByGroup[b.identifier] ?? []
                guard !membersA.isEmpty, !membersB.isEmpty else { continue }
                let overlap = membersA.intersection(membersB)
                guard !overlap.isEmpty else { continue }
                let smaller = min(membersA.count, membersB.count)
                let fraction = Double(overlap.count) / Double(smaller)
                if fraction >= 0.5 {
                    results.append(
                        OverlapPair(
                            first: a.identifier,
                            second: b.identifier,
                            firstName: a.name,
                            secondName: b.name,
                            overlapCount: overlap.count,
                            overlapFraction: fraction
                        )
                    )
                }
            }
        }
        return results.sorted { $0.overlapFraction > $1.overlapFraction }
    }
}
