import Contacts
import Foundation

enum ContactLabel {
    static func text(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}

extension DateComponents {
    var displayText: String {
        guard month != nil, day != nil else { return "" }
        var components = self
        let formatter = DateFormatter()
        if components.year == nil {
            // A leap year, so Feb 29 still resolves to a date.
            components.year = 2000
            formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        } else {
            formatter.dateStyle = .long
        }
        return Calendar(identifier: .gregorian).date(from: components).map(formatter.string(from:)) ?? ""
    }
}

/// Identifies a row for SwiftUI and links it back to the stored value it came
/// from. Never part of a row's content equality, so rebuilding a draft from a
/// contact compares equal to the draft it was saved from.
struct RowIdentity: Hashable, Sendable {
    let id = UUID()
    var sourceID: String?

    static func == (_: RowIdentity, _: RowIdentity) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

protocol DraftRow: Equatable, Identifiable, Sendable {
    var identity: RowIdentity { get }
    var label: String? { get }
    var isBlank: Bool { get }
    var summary: String { get }
}

extension DraftRow {
    var id: UUID { identity.id }
}

private func joined(_ parts: String...) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: ": ")
}

private func isEmpty(_ strings: String...) -> Bool {
    strings.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A labeled string: phone, email, URL, or related name.
struct DraftValue: DraftRow {
    var identity = RowIdentity()
    var label: String?
    var value = ""

    var isBlank: Bool { isEmpty(value) }
    var summary: String { joined(ContactLabel.text(label), value) }
}

struct DraftAddress: DraftRow {
    var identity = RowIdentity()
    var label: String?
    var street = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""
    // Not shown in the editor; kept so editing an address doesn't drop them.
    var subLocality = ""
    var subAdministrativeArea = ""
    var isoCountryCode = ""

    var isBlank: Bool { isEmpty(street, city, state, postalCode, country) }
    var summary: String {
        joined(ContactLabel.text(label),
               [street, city, state, postalCode, country].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    var postalAddress: CNPostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        address.state = state
        address.postalCode = postalCode
        address.country = country
        address.subLocality = subLocality
        address.subAdministrativeArea = subAdministrativeArea
        address.isoCountryCode = isoCountryCode
        return address
    }

    var mailingText: String {
        CNPostalAddressFormatter.string(from: postalAddress, style: .mailingAddress)
    }
}

/// A social profile or instant message address.
struct DraftService: DraftRow {
    var identity = RowIdentity()
    var label: String?
    var service = ""
    var username = ""

    var isBlank: Bool { isEmpty(username) }
    var summary: String { joined(service, username) }
}

struct DraftDate: DraftRow {
    var identity = RowIdentity()
    var label: String?
    var components = DateComponents()

    var isBlank: Bool { false }
    var summary: String { joined(ContactLabel.text(label), components.displayText) }
}

struct FieldChange: Equatable, Sendable {
    let field: String
    let oldValue: String
    let newValue: String
}

/// Everything the detail view can edit, as plain values. Edits accumulate here
/// and are written back to Contacts automatically.
struct ContactDraft: Equatable, Sendable {
    var isCompany = false
    var givenName = ""
    var familyName = ""
    var organizationName = ""
    var jobTitle = ""
    var departmentName = ""
    var nickname = ""
    var phones: [DraftValue] = []
    var emails: [DraftValue] = []
    var urls: [DraftValue] = []
    var relations: [DraftValue] = []
    var addresses: [DraftAddress] = []
    var social: [DraftService] = []
    var messaging: [DraftService] = []
    var dates: [DraftDate] = []
    var birthday: DateComponents?

    init() {}

    /// Reads the fields in `ContactsService.keysToFetch`.
    init(_ contact: CNContact) {
        isCompany = contact.contactType == .organization
        givenName = contact.givenName
        familyName = contact.familyName
        organizationName = contact.organizationName
        jobTitle = contact.jobTitle
        phones = contact.phoneNumbers.map {
            DraftValue(identity: RowIdentity(sourceID: $0.identifier), label: $0.label, value: $0.value.stringValue)
        }
        emails = contact.emailAddresses.map {
            DraftValue(identity: RowIdentity(sourceID: $0.identifier), label: $0.label, value: $0.value as String)
        }
        addresses = contact.postalAddresses.map {
            let address = $0.value
            return DraftAddress(
                identity: RowIdentity(sourceID: $0.identifier), label: $0.label,
                street: address.street, city: address.city, state: address.state,
                postalCode: address.postalCode, country: address.country,
                subLocality: address.subLocality, subAdministrativeArea: address.subAdministrativeArea,
                isoCountryCode: address.isoCountryCode
            )
        }
    }

    /// Reads the fields in `ContactsService.extraKeysToFetch`.
    init(extras contact: CNContact) {
        departmentName = contact.departmentName
        nickname = contact.nickname
        urls = contact.urlAddresses.map {
            DraftValue(identity: RowIdentity(sourceID: $0.identifier), label: $0.label, value: $0.value as String)
        }
        relations = contact.contactRelations.map {
            DraftValue(identity: RowIdentity(sourceID: $0.identifier), label: $0.label, value: $0.value.name)
        }
        social = contact.socialProfiles.map {
            DraftService(identity: RowIdentity(sourceID: $0.identifier), label: $0.label,
                         service: $0.value.service, username: $0.value.username)
        }
        messaging = contact.instantMessageAddresses.map {
            DraftService(identity: RowIdentity(sourceID: $0.identifier), label: $0.label,
                         service: $0.value.service, username: $0.value.username)
        }
        dates = contact.dates.map {
            DraftDate(identity: RowIdentity(sourceID: $0.identifier), label: $0.label, components: $0.value as DateComponents)
        }
        birthday = contact.birthday
    }

    /// Extra fields load after the rest, so they're merged in without touching
    /// anything already edited.
    mutating func adoptExtras(from other: ContactDraft) {
        departmentName = other.departmentName
        nickname = other.nickname
        urls = other.urls
        relations = other.relations
        social = other.social
        messaging = other.messaging
        dates = other.dates
        birthday = other.birthday
    }

    /// Without the rows the user added but never filled in.
    func normalized() -> ContactDraft {
        var draft = self
        draft.phones.removeAll(where: \.isBlank)
        draft.emails.removeAll(where: \.isBlank)
        draft.urls.removeAll(where: \.isBlank)
        draft.relations.removeAll(where: \.isBlank)
        draft.addresses.removeAll(where: \.isBlank)
        draft.social.removeAll(where: \.isBlank)
        draft.messaging.removeAll(where: \.isBlank)
        return draft
    }

    func changes(to other: ContactDraft) -> [FieldChange] {
        let old = normalized()
        let new = other.normalized()
        var result: [FieldChange] = []

        func add<T: Equatable>(_ field: String, _ before: T, _ after: T, text: (T) -> String) {
            if before != after {
                result.append(FieldChange(field: field, oldValue: text(before), newValue: text(after)))
            }
        }
        func add(_ field: String, _ before: String, _ after: String) {
            add(field, before, after) { $0 }
        }
        func add<R: DraftRow>(_ field: String, _ before: [R], _ after: [R]) {
            add(field, before, after) { $0.map(\.summary).joined(separator: "\n") }
        }

        add("Type", old.isCompany, new.isCompany) { $0 ? "Company" : "Person" }
        add("First Name", old.givenName, new.givenName)
        add("Last Name", old.familyName, new.familyName)
        add("Company", old.organizationName, new.organizationName)
        add("Job Title", old.jobTitle, new.jobTitle)
        add("Department", old.departmentName, new.departmentName)
        add("Nickname", old.nickname, new.nickname)
        add("Phone", old.phones, new.phones)
        add("Email", old.emails, new.emails)
        add("URL", old.urls, new.urls)
        add("Address", old.addresses, new.addresses)
        add("Birthday", old.birthday, new.birthday) { $0?.displayText ?? "" }
        add("Dates", old.dates, new.dates)
        add("Related Names", old.relations, new.relations)
        add("Social Profiles", old.social, new.social)
        add("Instant Messages", old.messaging, new.messaging)
        return result
    }

    /// Writes only what changed since `baseline`, reusing the identifiers of
    /// rows that already exist so Contacts sees edits rather than replacements.
    func apply(to contact: CNMutableContact, baseline: ContactDraft) {
        let old = baseline.normalized()
        let new = normalized()

        if old.isCompany != new.isCompany { contact.contactType = new.isCompany ? .organization : .person }
        if old.givenName != new.givenName { contact.givenName = new.givenName }
        if old.familyName != new.familyName { contact.familyName = new.familyName }
        if old.organizationName != new.organizationName { contact.organizationName = new.organizationName }
        if old.jobTitle != new.jobTitle { contact.jobTitle = new.jobTitle }
        if old.departmentName != new.departmentName { contact.departmentName = new.departmentName }
        if old.nickname != new.nickname { contact.nickname = new.nickname }
        if old.birthday != new.birthday { contact.birthday = new.birthday }

        if old.phones != new.phones {
            contact.phoneNumbers = Self.rebuild(contact.phoneNumbers, new.phones) { CNPhoneNumber(stringValue: $0.value) }
        }
        if old.emails != new.emails {
            contact.emailAddresses = Self.rebuild(contact.emailAddresses, new.emails) { $0.value as NSString }
        }
        if old.urls != new.urls {
            contact.urlAddresses = Self.rebuild(contact.urlAddresses, new.urls) { $0.value as NSString }
        }
        if old.relations != new.relations {
            contact.contactRelations = Self.rebuild(contact.contactRelations, new.relations) { CNContactRelation(name: $0.value) }
        }
        if old.addresses != new.addresses {
            contact.postalAddresses = Self.rebuild(contact.postalAddresses, new.addresses) { $0.postalAddress }
        }
        if old.social != new.social {
            contact.socialProfiles = Self.rebuild(contact.socialProfiles, new.social) {
                CNSocialProfile(urlString: nil, username: $0.username, userIdentifier: nil, service: $0.service)
            }
        }
        if old.messaging != new.messaging {
            contact.instantMessageAddresses = Self.rebuild(contact.instantMessageAddresses, new.messaging) {
                CNInstantMessageAddress(username: $0.username, service: $0.service)
            }
        }
        if old.dates != new.dates {
            contact.dates = Self.rebuild(contact.dates, new.dates) { $0.components as NSDateComponents }
        }
    }

    private static func rebuild<V: NSCopying & NSSecureCoding, R: DraftRow>(
        _ existing: [CNLabeledValue<V>], _ rows: [R], make: (R) -> V
    ) -> [CNLabeledValue<V>] {
        rows.map { row in
            if let sourceID = row.identity.sourceID,
               let current = existing.first(where: { $0.identifier == sourceID }) {
                return current.settingLabel(row.label).settingValue(make(row))
            }
            return CNLabeledValue(label: row.label, value: make(row))
        }
    }
}
