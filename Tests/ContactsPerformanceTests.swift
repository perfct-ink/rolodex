import Contacts
import Foundation

private actor SnapshotLoader {
    let snapshot: ContactsSnapshot
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    var shouldFail = false

    init(snapshot: ContactsSnapshot) { self.snapshot = snapshot }

    func setFailure(_ value: Bool) { shouldFail = value }

    func load() async throws -> ContactsSnapshot {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(50))
        if shouldFail { throw NSError(domain: "Test", code: 1) }
        return snapshot
    }
}

@main
struct ContactsPerformanceTests {
    @MainActor
    static func main() async throws {
        try await testBackgroundQueue()
        // Synthetic fixtures only; these tests never read or write the contact store.
        let alice = CNMutableContact()
        alice.givenName = "Alice"
        alice.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "alice@example.com" as NSString)]
        let bob = CNMutableContact()
        bob.givenName = "Bob"
        bob.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+1 555 1234"))]
        let carol = CNMutableContact()
        carol.givenName = "Carol"
        let archived = CNMutableGroup()
        archived.name = "Archived"
        let friends = CNMutableGroup()
        friends.name = "Friends"
        let empty = CNMutableGroup()
        empty.name = "Empty"
        let snapshot = ContactsSnapshot(
            contacts: [carol, bob, alice], groups: [friends, empty, archived],
            membership: [alice.identifier: [friends.identifier], bob.identifier: [archived.identifier, friends.identifier]]
        )
        precondition(snapshot.contacts.map(\.givenName) == ["Alice", "Bob", "Carol"])
        precondition(snapshot.groups.map(\.name) == ["Archived", "Empty", "Friends"])
        precondition(snapshot.contactsByID[bob.identifier] === bob)
        precondition(snapshot.membersByGroup[friends.identifier] == [alice.identifier, bob.identifier])

        let loader = SnapshotLoader(snapshot: snapshot)
        let model = ContactsViewModel(loadSnapshot: { try await loader.load() })
        model.smartGroups = []
        model.hiddenGroupIdentifiers = []

        let initialRefresh = Task { await model.refreshAll() }
        while await loader.calls == 0 { await Task.yield() }
        precondition(model.isLoading)
        // A suspended load leaves the main actor available to handle UI work.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await model.refreshAll() } }
        }
        await initialRefresh.value
        let calls = await loader.calls
        let maximumActive = await loader.maximumActive
        precondition(calls == 2, "Overlapping refreshes should produce one follow-up load")
        precondition(maximumActive == 1, "Loads must not overlap")
        precondition(!model.isLoading && model.errorMessage == nil)
        precondition(model.visibleContacts.count == 3)

        model.searchText = "ALICE@EXAMPLE"
        precondition(model.visibleContacts.map(\.identifier) == [alice.identifier])
        model.searchText = "555"
        precondition(model.visibleContacts.map(\.identifier) == [bob.identifier])
        model.searchText = ""
        model.hiddenGroupIdentifiers = [archived.identifier]
        precondition(model.visibleContacts.map(\.givenName) == ["Alice", "Carol"])
        model.selection = .group(archived.identifier)
        precondition(model.visibleContacts.map(\.identifier) == [bob.identifier])
        precondition(model.emptyGroups.map(\.identifier) == [empty.identifier])
        precondition(model.contactsWithoutGroup.map(\.identifier) == [carol.identifier])
        precondition(model.groupStats.first?.count == 2)
        precondition(model.overlappingGroupPairs.count == 1)
        precondition(model.overlappingGroupPairs.first?.overlapFraction == 1)

        await loader.setFailure(true)
        await model.refreshAll()
        precondition(!model.isLoading && model.errorMessage != nil)
        precondition(model.contacts.count == 3, "Failed loads must retain existing contacts")
        await loader.setFailure(false)
        await model.refreshAll()
        precondition(model.errorMessage == nil)

        print("Passed: background queue responsiveness, snapshot indexes, filtering, insights, refresh coalescing, and error recovery.")
        testDraftEditing()
        testHistoryStore()
        print("Passed: draft diffing, minimal writes, identifier reuse, and history coalescing.")
    }

    @MainActor
    private static func testDraftEditing() {
        let contact = CNMutableContact()
        contact.givenName = "Dana"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-0100")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "555-0101")),
        ]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "dana@example.com" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "1 Main St"
        address.city = "Springfield"
        address.subLocality = "Old Town"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]

        let baseline = ContactDraft(contact)
        precondition(baseline == ContactDraft(contact), "Rebuilding a draft must compare equal; row identity is not content")

        var untouched = baseline
        untouched.phones.append(DraftValue(label: CNLabelHome))
        precondition(baseline.changes(to: untouched).isEmpty, "A blank row the user never filled in is not a change")

        var edited = baseline
        edited.givenName = "Dani"
        edited.phones[1].value = "555-0199"
        edited.phones.append(DraftValue(label: CNLabelHome, value: "555-0102"))
        edited.addresses[0].city = "Shelbyville"
        let changes = baseline.changes(to: edited)
        precondition(changes.map(\.field) == ["First Name", "Phone", "Address"])
        precondition(changes[0].oldValue == "Dana" && changes[0].newValue == "Dani")

        var retyped = baseline
        retyped.isCompany = true
        let retypedChanges = baseline.changes(to: retyped)
        precondition(retypedChanges == [FieldChange(field: "Type", oldValue: "Person", newValue: "Company")])
        let retypedContact = contact.mutableCopy() as! CNMutableContact
        retyped.apply(to: retypedContact, baseline: baseline)
        precondition(retypedContact.contactType == .organization && contact.contactType == .person)

        let target = contact.mutableCopy() as! CNMutableContact
        let originalIDs = contact.phoneNumbers.map(\.identifier)
        let emailID = contact.emailAddresses[0].identifier
        edited.apply(to: target, baseline: baseline)
        precondition(target.givenName == "Dani")
        precondition(target.phoneNumbers.map(\.value.stringValue) == ["555-0100", "555-0199", "555-0102"])
        precondition(Array(target.phoneNumbers.map(\.identifier).prefix(2)) == originalIDs,
                     "Edited rows must keep their identifiers so Contacts sees an edit, not a replacement")
        precondition(target.emailAddresses[0].identifier == emailID, "Unchanged sections must not be rewritten")
        precondition(target.postalAddresses[0].value.city == "Shelbyville")
        precondition(target.postalAddresses[0].value.subLocality == "Old Town", "Hidden address fields must survive an edit")

        var removed = edited
        removed.phones.removeAll { $0.value == "555-0100" }
        let afterRemoval = target.mutableCopy() as! CNMutableContact
        removed.apply(to: afterRemoval, baseline: edited)
        precondition(afterRemoval.phoneNumbers.map(\.value.stringValue) == ["555-0199", "555-0102"])

        let extras = CNMutableContact()
        extras.nickname = "D"
        extras.birthday = DateComponents(month: 2, day: 29)
        var withExtras = baseline
        withExtras.adoptExtras(from: ContactDraft(extras: extras))
        precondition(withExtras.givenName == "Dana" && withExtras.nickname == "D")
        precondition(baseline.changes(to: withExtras).map(\.field) == ["Nickname", "Birthday"])
        precondition(withExtras.birthday?.displayText.isEmpty == false, "A yearless Feb 29 birthday must format")
    }

    @MainActor
    private static func testHistoryStore() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rolodex-history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContactHistoryStore(fileURL: url)
        let start = Date()

        store.record([FieldChange(field: "Company", oldValue: "A", newValue: "Ac")], contactID: "1", at: start)
        store.record([FieldChange(field: "Company", oldValue: "Ac", newValue: "Acme")], contactID: "1", at: start + 5)
        precondition(store.entries(for: "1").count == 1, "Edits seconds apart are one change")
        precondition(store.entries(for: "1")[0].oldValue == "A" && store.entries(for: "1")[0].newValue == "Acme")

        store.record([FieldChange(field: "Company", oldValue: "Acme", newValue: "Other")], contactID: "2", at: start + 6)
        precondition(store.entries(for: "1").count == 1 && store.entries(for: "2").count == 1,
                     "Contacts must not coalesce with each other")

        store.record([FieldChange(field: "Company", oldValue: "Acme", newValue: "A")], contactID: "1", at: start + 10)
        precondition(store.entries(for: "1").isEmpty, "Editing a value back to where it started leaves no change")

        store.record([FieldChange(field: "Company", oldValue: "A", newValue: "B")], contactID: "1", at: start + 1000)
        store.record([FieldChange(field: "Company", oldValue: "B", newValue: "C")], contactID: "1", at: start + 2000)
        precondition(store.entries(for: "1").map(\.newValue) == ["C", "B"], "Newest first; distant edits stay separate")

        let reloaded = ContactHistoryStore(fileURL: url)
        precondition(reloaded.entries(for: "1").map(\.newValue) == ["C", "B"], "History must survive a relaunch")
        reloaded.clear(contactID: "1")
        precondition(reloaded.entries(for: "1").isEmpty && reloaded.entries(for: "2").count == 1)
    }

    @MainActor
    private static func testBackgroundQueue() async throws {
        let worker = ContactsIOQueue()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queued = DispatchSemaphore(value: 0)
        let blockedWork = Task {
            try await worker.run {
                started.signal()
                let released = release.wait(timeout: .now() + 2) == .success
                return (!Thread.isMainThread, released)
            }
        }
        // Wait asynchronously for the worker to enter a blocking operation.
        while !consumeSignal(started) { await Task.yield() }
        worker.enqueue { queued.signal() }
        precondition(!consumeSignal(queued), "The worker must serialize operations")
        // Only UI/main-actor work can release the worker. A UI-blocking
        // implementation would time out before reaching this line.
        release.signal()
        let (ranInBackground, wasReleased) = try await blockedWork.value
        precondition(ranInBackground && wasReleased, "Contacts work must leave the UI responsive")
        let drained = try await worker.run { queued.wait(timeout: .now()) == .success }
        precondition(drained)
        do {
            let _: Void = try await worker.run { throw NSError(domain: "QueueTest", code: 42) }
            preconditionFailure("Queue must propagate errors")
        } catch {
            precondition((error as NSError).code == 42)
        }
        let recovered = try await worker.run { !Thread.isMainThread }
        precondition(recovered, "Worker must remain usable after a failed operation")
    }

    private static func consumeSignal(_ semaphore: DispatchSemaphore) -> Bool {
        // A zero timeout only polls; it never blocks the calling thread.
        semaphore.wait(timeout: .now()) == .success
    }
}
