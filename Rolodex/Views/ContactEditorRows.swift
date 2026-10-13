import AppKit
import Contacts
import SwiftUI

enum ContactLabels {
    static let phone = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelHome, CNLabelWork, CNLabelPhoneNumberMain, CNLabelOther]
    static let email = [CNLabelHome, CNLabelWork, CNLabelOther]
    static let url = [CNLabelURLAddressHomePage, CNLabelHome, CNLabelWork, CNLabelOther]
    static let address = [CNLabelHome, CNLabelWork, CNLabelOther]
    static let date = [CNLabelDateAnniversary, CNLabelOther]
    static let relation = [
        CNLabelContactRelationFather, CNLabelContactRelationMother, CNLabelContactRelationParent,
        CNLabelContactRelationBrother, CNLabelContactRelationSister, CNLabelContactRelationChild,
        CNLabelContactRelationFriend, CNLabelContactRelationSpouse, CNLabelContactRelationPartner,
        CNLabelContactRelationAssistant, CNLabelContactRelationManager, CNLabelOther,
    ]
}

private let labelColumnWidth: CGFloat = 76

struct LabelMenu: View {
    @Binding var label: String?
    let options: [String]

    var body: some View {
        Menu {
            ForEach(allOptions, id: \.self) { option in
                Button(ContactLabel.text(option)) { label = option }
            }
        } label: {
            Text(ContactLabel.text(label).isEmpty ? "label" : ContactLabel.text(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelColumnWidth, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // A custom label set elsewhere stays selectable.
    private var allOptions: [String] {
        if let label, !label.isEmpty, !options.contains(label) { return [label] + options }
        return options
    }
}

private struct DeleteRowButton: View {
    let fieldName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove \(fieldName)")
        .accessibilityLabel("Remove \(fieldName)")
    }
}

/// Phone, email, URL, or related name. `accessory` adds row-specific buttons.
struct LabeledValueRow<Accessory: View>: View {
    @Binding var row: DraftValue
    let labels: [String]
    let placeholder: String
    let fieldName: String
    let onDelete: () -> Void
    let accessory: Accessory

    init(row: Binding<DraftValue>, labels: [String], placeholder: String, fieldName: String,
         onDelete: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        _row = row
        self.labels = labels
        self.placeholder = placeholder
        self.fieldName = fieldName
        self.onDelete = onDelete
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            LabelMenu(label: $row.label, options: labels)
            TextField("", text: $row.value, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .accessibilityLabel(fieldName)
            accessory
            DeleteRowButton(fieldName: fieldName, action: onDelete)
        }
        .padding(.vertical, 8)
        .modifier(ContactFieldCopy(value: row.value, fieldName: fieldName))
    }
}

extension LabeledValueRow where Accessory == EmptyView {
    init(row: Binding<DraftValue>, labels: [String], placeholder: String, fieldName: String,
         onDelete: @escaping () -> Void) {
        self.init(row: row, labels: labels, placeholder: placeholder, fieldName: fieldName, onDelete: onDelete) {
            EmptyView()
        }
    }
}

struct AddressRow: View {
    @Binding var row: DraftAddress
    let isShowingMap: Bool
    let onToggleMap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    LabelMenu(label: $row.label, options: ContactLabels.address)
                    Spacer()
                    DeleteRowButton(fieldName: "address", action: onDelete)
                }
                TextField("", text: $row.street, prompt: Text("Street"), axis: .vertical)
                HStack(spacing: 8) {
                    TextField("", text: $row.city, prompt: Text("City"))
                    TextField("", text: $row.state, prompt: Text("State"))
                        .frame(maxWidth: 80)
                    TextField("", text: $row.postalCode, prompt: Text("ZIP"))
                        .frame(maxWidth: 80)
                }
                TextField("", text: $row.country, prompt: Text("Country"))
            }
            .textFieldStyle(.plain)
            .labelsHidden()

            Button(action: onToggleMap) {
                Image(systemName: isShowingMap ? "map.fill" : "map")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(row.isBlank)
            .help(isShowingMap ? "Hide Map" : "Show on Map")
            .accessibilityLabel(isShowingMap ? "Hide Map" : "Show on Map")
        }
        .padding(.vertical, 8)
        .modifier(ContactFieldCopy(value: row.mailingText, fieldName: "postal address"))
    }
}

/// A social profile or instant message address.
struct ServiceRow: View {
    @Binding var row: DraftService
    let kind: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(kind)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            TextField("", text: $row.service, prompt: Text("Service"))
                .frame(maxWidth: 110)
            TextField("", text: $row.username, prompt: Text("Username"))
            DeleteRowButton(fieldName: kind.lowercased(), action: onDelete)
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .padding(.vertical, 8)
        .modifier(ContactFieldCopy(value: row.username, fieldName: kind.lowercased()))
    }
}

/// A birthday (fixed title) or a labeled date. The year is optional, as in Contacts.
struct DateRow: View {
    var title = "Birthday"
    var label: Binding<String?>?
    @Binding var components: DateComponents
    let onDelete: () -> Void

    private static let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                LabelMenu(label: label, options: ContactLabels.date)
            } else {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: labelColumnWidth, alignment: .leading)
            }
            DatePicker("", selection: dateBinding, displayedComponents: .date)
                .labelsHidden()
            Toggle("Year", isOn: yearBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            DeleteRowButton(fieldName: title.lowercased(), action: onDelete)
        }
        .padding(.vertical, 8)
        .modifier(ContactFieldCopy(value: components.displayText, fieldName: title.lowercased()))
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                var shown = components
                shown.year = shown.year ?? 2000
                return Self.calendar.date(from: shown) ?? Date()
            },
            set: { date in
                let picked = Self.calendar.dateComponents([.year, .month, .day], from: date)
                components.month = picked.month
                components.day = picked.day
                if components.year != nil { components.year = picked.year }
            }
        )
    }

    private var yearBinding: Binding<Bool> {
        Binding(
            get: { components.year != nil },
            set: { components.year = $0 ? Self.calendar.component(.year, from: Date()) : nil }
        )
    }
}

/// Adds a trailing copy button that appears on hover. Copying animates the icon.
struct ContactFieldCopy: ViewModifier {
    let value: String
    let fieldName: String

    @State private var isHovered = false
    @State private var isCopied = false
    @State private var copyCount = 0
    @State private var resetTask: Task<Void, Never>?
    @FocusState private var isCopyFocused: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 8) {
            content
            Button(action: copy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? Color.green : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: copyCount)
            }
            .buttonStyle(.plain)
            .focused($isCopyFocused)
            .help("Copy \(fieldName)")
            .accessibilityLabel("Copy \(fieldName)")
            .opacity(isHovered || isCopyFocused || isCopied ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copyCount += 1
        withAnimation { isCopied = true }
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { isCopied = false }
        }
    }
}
