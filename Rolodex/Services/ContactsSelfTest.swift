#if DEBUG
import Contacts
import Foundation

/// Checks that the edits Rolodex makes are accepted by the real Contacts API
/// and read back exactly. Run with `make test-contacts`.
///
/// It creates one temporary contact (given name "RolodexSelfTest"), edits it
/// through `ContactsService`, and deletes it afterwards. Any left over from an
/// interrupted run are removed before and after. No other contact is touched.
@MainActor
enum ContactsSelfTest {
    private static let givenName = "RolodexSelfTest"
    private static let familyPrefix = "Fixture"

    private static var checks = 0
    private static var failures = 0

    static func runAndExit() async -> Never {
        fputs("SELFTEST started\n", stderr)
        let reachedEnd = await run()
        let passed = reachedEnd && failures == 0
        fputs(passed ? "SELFTEST PASSED (\(checks) checks)\n" : "SELFTEST FAILED (\(failures) of \(checks) checks failed)\n", stderr)
        exit(passed ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if condition {
            fputs("  ok    \(message)\n", stderr)
        } else {
            failures += 1
            fputs("  FAIL  \(message) (ContactsSelfTest.swift:\(line))\n", stderr)
        }
    }

    // MARK: - Run

    private static func run() async -> Bool {
        guard await hasAccess() else {
            fputs("FAIL  Contacts access was not granted; approve the prompt and run again\n", stderr)
            return false
        }
        let service = ContactsService.shared
        var completed = false
        do {
            try await removeFixtures(service)
            let id = try await createFixture(service)
            do {
                try await scenarios(service, id: id)
                completed = true
            } catch {
                check(false, "scenarios threw: \(error)")
            }
            try await removeFixtures(service)
            let remaining = try await fixtures(service)
            check(remaining.isEmpty, "the temporary contact was deleted")
        } catch {
            check(false, "setup or cleanup threw: \(error)")
            try? await removeFixtures(service)
        }
        return completed
    }

    // The permission prompt can only be answered by a person, so wait for them, but not forever.
    private static func hasAccess() async -> Bool {
        Task { _ = await ContactsService.shared.requestAccess() }
        for _ in 0..<180 {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .notDetermined:
                try? await Task.sleep(for: .milliseconds(500))
            case .authorized, .limited:
                return true
            default:
                return false
            }
        }
        return false
    }

    // MARK: - Fixture

    private static func fixtures(_ service: ContactsService) async throws -> [CNContact] {
        try await service.contacts(matchingName: givenName).filter {
            $0.givenName == givenName && $0.familyName.hasPrefix(familyPrefix)
        }
    }

    private static func removeFixtures(_ service: ContactsService) async throws {
        let found = try await fixtures(service)
        if !found.isEmpty { try await service.delete(found) }
    }

    private static func createFixture(_ service: ContactsService) async throws -> String {
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = "\(familyPrefix) \(UUID().uuidString.prefix(8))"
        contact.organizationName = "Acme"
        contact.jobTitle = "Tester"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-0100")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "555-0101")),
        ]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "selftest@rolodex.invalid" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "1 Main St"
        address.city = "Springfield"
        address.state = "IL"
        address.postalCode = "62701"
        address.country = "United States"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        let created = try await service.createContact(contact, in: [])
        return created.identifier
    }

    // MARK: - Helpers

    private static func read(_ service: ContactsService, _ id: String) async throws -> (CNContact, ContactDraft) {
        let contact = try await service.fetchContact(identifier: id)
        var draft = ContactDraft(contact)
        draft.adoptExtras(from: ContactDraft(extras: contact))
        return (contact, draft)
    }

    /// Edits the draft, writes the difference exactly as the app does, and reads
    /// the contact back. The read-back draft must equal what was intended.
    private static func edit(
        _ name: String, _ service: ContactsService, _ id: String, from baseline: ContactDraft,
        _ change: (inout ContactDraft) -> Void
    ) async throws -> (CNContact, ContactDraft) {
        var intended = baseline
        change(&intended)
        let target = intended
        try await service.updateContact(identifier: id) { target.apply(to: $0, baseline: baseline) }
        let result = try await read(service, id)
        let differences = intended.changes(to: result.1)
        check(result.1.normalized() == intended.normalized(), "\(name): saved values read back exactly"
              + differences.map { "\n          \($0.field): wrote [\($0.oldValue)] read back [\($0.newValue)]" }.joined())
        let fields = baseline.changes(to: result.1).map(\.field)
        check(fields == baseline.changes(to: intended).map(\.field), "\(name): history would record \(fields.joined(separator: ", "))")
        return result
    }

    // MARK: - Scenarios

    private static func scenarios(_ service: ContactsService, id: String) async throws {
        var (contact, current) = try await read(service, id)
        let original = current
        check(original.phones.count == 2 && original.emails.count == 1 && original.addresses.count == 1,
              "the fixture reads back with its phones, email and address")
        check(!original.isCompany, "the fixture starts as a person")

        // Text fields, including ones that load separately from the list.
        let phoneIDs = contact.phoneNumbers.map(\.identifier)
        (contact, current) = try await edit("text fields", service, id, from: current) {
            $0.organizationName = "Acme Labs"
            $0.jobTitle = "Lead Tester"
            $0.departmentName = "QA"
            $0.nickname = "Tess"
        }
        check(contact.organizationName == "Acme Labs" && contact.jobTitle == "Lead Tester", "company and job title saved")
        check(contact.departmentName == "QA" && contact.nickname == "Tess", "department and nickname saved")
        check(contact.phoneNumbers.map(\.identifier) == phoneIDs, "untouched phones kept their identifiers")

        // Editing, adding, and relabeling rows.
        let addressBefore = contact.postalAddresses[0].value
        (contact, current) = try await edit("rows", service, id, from: current) {
            $0.phones[1].value = "555-0199"
            $0.phones.append(DraftValue(label: CNLabelHome, value: "555-0102"))
            $0.emails[0].label = CNLabelWork
            $0.urls.append(DraftValue(label: CNLabelURLAddressHomePage, value: "https://rolodex.invalid"))
            $0.addresses[0].city = "Shelbyville"
            $0.addresses.append(DraftAddress(
                label: CNLabelWork, street: "2 Side St", city: "Capital City",
                state: "IL", postalCode: "62702", country: "United States"
            ))
        }
        check(contact.phoneNumbers.map(\.value.stringValue) == ["555-0100", "555-0199", "555-0102"], "phone edited and added")
        check(Array(contact.phoneNumbers.map(\.identifier).prefix(2)) == phoneIDs, "edited phone kept its identifier")
        check(contact.emailAddresses.first?.label == CNLabelWork, "email relabeled")
        check(contact.urlAddresses.map { $0.value as String } == ["https://rolodex.invalid"], "URL added")
        let addressAfter = contact.postalAddresses[0].value
        check(addressAfter.city == "Shelbyville" && contact.postalAddresses.count == 2, "address edited and added")
        check(addressAfter.subLocality == addressBefore.subLocality
              && addressAfter.subAdministrativeArea == addressBefore.subAdministrativeArea
              && addressAfter.isoCountryCode == addressBefore.isoCountryCode,
              "address fields the editor doesn't show survived the edit")

        // Person and company.
        (contact, current) = try await edit("company", service, id, from: current) { $0.isCompany = true }
        check(contact.contactType == .organization, "contact type changed to company")
        (contact, current) = try await edit("person", service, id, from: current) { $0.isCompany = false }
        check(contact.contactType == .person, "contact type changed back to person")

        // The rarer multi-value fields.
        (contact, current) = try await edit("dates, relations and profiles", service, id, from: current) {
            $0.birthday = DateComponents(month: 3, day: 14)
            $0.dates.append(DraftDate(label: CNLabelDateAnniversary, components: DateComponents(year: 2020, month: 6, day: 1)))
            $0.relations.append(DraftValue(label: CNLabelContactRelationFriend, value: "Pat Example"))
            $0.social.append(DraftService(service: "Mastodon", username: "selftest"))
            $0.messaging.append(DraftService(service: "Jabber", username: "selftest@rolodex.invalid"))
        }
        check(contact.birthday?.month == 3 && contact.birthday?.day == 14 && contact.birthday?.year == nil, "birthday without a year")
        check(contact.dates.first?.value.year == 2020, "labeled date with a year")
        check(contact.contactRelations.first?.value.name == "Pat Example", "related name")
        check(contact.socialProfiles.first?.value.username == "selftest", "social profile")
        check(contact.instantMessageAddresses.first?.value.username == "selftest@rolodex.invalid", "instant message")

        // Removal.
        (contact, current) = try await edit("removal", service, id, from: current) {
            $0.phones.removeFirst()
            $0.birthday = nil
            $0.urls.removeAll()
            $0.addresses.removeLast()
        }
        check(contact.phoneNumbers.count == 2 && contact.birthday == nil && contact.urlAddresses.isEmpty, "rows and birthday removed")
        check(contact.postalAddresses.count == 1, "address removed")

        // Undo: applying the original draft over the edited one restores the contact.
        let edited = current
        try await service.updateContact(identifier: id) { original.apply(to: $0, baseline: edited) }
        (contact, current) = try await read(service, id)
        check(current.normalized() == original.normalized(), "undo: restoring the original draft restores the contact")
        let remainingChanges = original.changes(to: current)
        check(remainingChanges.isEmpty, "undo: nothing differs from the original (\(remainingChanges.map(\.field).joined(separator: ", ")))")
    }
}
#endif
