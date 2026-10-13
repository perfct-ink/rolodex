import Contacts
import Foundation

struct ContactsSnapshot {
    let contacts: [CNContact]
    let groups: [CNGroup]
    let membership: [String: Set<String>]
    let contactsByID: [String: CNContact]
    let membersByGroup: [String: Set<String>]
    let searchTextByID: [String: [String]]

    init(contacts: [CNContact], groups: [CNGroup], membership: [String: Set<String>]) {
        // Format each name once, rather than on every sorting comparison.
        let namedContacts = contacts.map { ($0, $0.displayName) }
        self.contacts = namedContacts.sorted {
            $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending
        }.map { $0.0 }
        self.groups = groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.membership = membership
        contactsByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.identifier, $0) })
        searchTextByID = Dictionary(uniqueKeysWithValues: namedContacts.map { contact, name in
            (contact.identifier, [name, contact.primaryEmail ?? "", contact.primaryPhone ?? "", contact.organizationName]
                .map { $0.lowercased() })
        })
        var members: [String: Set<String>] = [:]
        for contact in contacts {
            for groupID in membership[contact.identifier] ?? [] {
                members[groupID, default: []].insert(contact.identifier)
            }
        }
        membersByGroup = members
    }
}

// A serial queue keeps blocking Contacts calls off both the UI thread and
// Swift's cooperative executor. Every store access goes through this queue.
final class ContactsIOQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rolodex.contacts-io", qos: .userInitiated)

    func enqueue(_ operation: @escaping () -> Void) {
        queue.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            autoreleasepool(invoking: operation)
        }
    }

    func run<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let value = try operation()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// The mutable store is confined to ioQueue, including its lazy initialization.
final class ContactsService: @unchecked Sendable {
    static let shared = ContactsService()

    private let ioQueue = ContactsIOQueue()
    private lazy var store = CNContactStore()

    static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
    ]

    // Fields shown in the detail view. Fetched per contact on demand so they
    // don't slow down loading the whole list. Notes are omitted: reading them
    // needs a restricted entitlement.
    static let extraKeysToFetch: [CNKeyDescriptor] = [
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactDatesKey as CNKeyDescriptor,
        CNContactRelationsKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactInstantMessageAddressesKey as CNKeyDescriptor,
    ]

    func fetchSnapshot() async throws -> ContactsSnapshot {
        try await ioQueue.run { [self] in
            let groups = try fetchGroups()
            return try ContactsSnapshot(
                contacts: fetchAllContacts(), groups: groups,
                membership: fetchMembership(for: groups)
            )
        }
    }

    func fetchExtraFields(identifier: String) async throws -> CNContact {
        try await ioQueue.run { [self] in
            try store.unifiedContact(withIdentifier: identifier, keysToFetch: Self.extraKeysToFetch)
        }
    }

    func fetchImageData(identifier: String) async throws -> Data? {
        try await ioQueue.run { [self] in
            try store.unifiedContact(withIdentifier: identifier, keysToFetch: [CNContactImageDataKey as CNKeyDescriptor]).imageData
        }
    }

    func exportVCardURL(identifier: String, name: String) async throws -> URL {
        try await ioQueue.run { [self] in
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
            let data = try CNContactVCardSerialization.data(with: [contact])
            let fileName = name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName).vcf")
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.enqueue { [self] in
                let status = CNContactStore.authorizationStatus(for: .contacts)
                print("Rolodex: Contacts TCC status at startup = \(status)")
                switch status {
                case .authorized, .limited:
                    continuation.resume(returning: true)
                case .notDetermined:
                    store.requestAccess(for: .contacts) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                default:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func fetchAllContacts() throws -> [CNContact] {
        var results: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        // The snapshot sorts by display name, so don't also sort in the store.
        request.sortOrder = .none
        try store.enumerateContacts(with: request) { contact, _ in
            results.append(contact)
        }
        return results
    }

    private func fetchGroups() throws -> [CNGroup] {
        try store.groups(matching: nil)
    }

    private func fetchMembership(for groups: [CNGroup]) throws -> [String: Set<String>] {
        var membership: [String: Set<String>] = [:]
        for group in groups {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
            let members = try store.unifiedContacts(matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            for member in members {
                membership[member.identifier, default: []].insert(group.identifier)
            }
        }
        return membership
    }

    // MARK: - Groups

    @discardableResult
    func createGroup(named name: String) async throws -> CNGroup {
        try await ioQueue.run { [self] in
            let newGroup = CNMutableGroup()
            newGroup.name = name
            let request = CNSaveRequest()
            request.add(newGroup, toContainerWithIdentifier: nil)
            try store.execute(request)
            return newGroup
        }
    }

    func rename(group: CNGroup, to newName: String) async throws {
        try await ioQueue.run { [self] in
            guard let mutable = group.mutableCopy() as? CNMutableGroup else { return }
            mutable.name = newName
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }
    }

    func delete(group: CNGroup) async throws {
        try await ioQueue.run { [self] in
            guard let mutable = group.mutableCopy() as? CNMutableGroup else { return }
            let request = CNSaveRequest()
            request.delete(mutable)
            try store.execute(request)
        }
    }

    func addContacts(_ contacts: [CNContact], to group: CNGroup) async throws {
        try await ioQueue.run { [self] in
            let request = CNSaveRequest()
            for contact in contacts {
                request.addMember(contact, to: group)
            }
            try store.execute(request)
        }
    }

    func removeContacts(_ contacts: [CNContact], from group: CNGroup) async throws {
        try await ioQueue.run { [self] in
            let request = CNSaveRequest()
            for contact in contacts {
                request.removeMember(contact, from: group)
            }
            try store.execute(request)
        }
    }

    func mergeGroup(_ source: CNGroup, into destination: CNGroup) async throws {
        try await ioQueue.run { [self] in
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: source.identifier)
            let members = try store.unifiedContacts(matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])

            let request = CNSaveRequest()
            for member in members {
                request.addMember(member, to: destination)
            }
            if let mutableSource = source.mutableCopy() as? CNMutableGroup {
                request.delete(mutableSource)
            }
            try store.execute(request)
        }
    }

    // MARK: - Contacts

    @discardableResult
    func createContact(_ contact: CNMutableContact, in groups: [CNGroup]) async throws -> CNContact {
        try await ioQueue.run { [self] in
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            for group in groups {
                request.addMember(contact, to: group)
            }
            try store.execute(request)
            return contact
        }
    }

    // Edits a freshly fetched copy with every editable key, so the caller can
    // touch any field without hitting an unfetched property.
    func updateContact(identifier: String, _ apply: @escaping (CNMutableContact) -> Void) async throws {
        try await ioQueue.run { [self] in
            let fetched = try store.unifiedContact(
                withIdentifier: identifier, keysToFetch: Self.keysToFetch + Self.extraKeysToFetch
            )
            guard let mutable = fetched.mutableCopy() as? CNMutableContact else { return }
            apply(mutable)
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }
    }

    func delete(_ contacts: [CNContact]) async throws {
        try await ioQueue.run { [self] in
            let request = CNSaveRequest()
            for contact in contacts {
                if let mutable = contact.mutableCopy() as? CNMutableContact {
                    request.delete(mutable)
                }
            }
            try store.execute(request)
        }
    }
}
