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

/// Every row starts with a label column this wide, so values line up whatever the field.
let contactLabelColumnWidth: CGFloat = 76

// MARK: - Hover

/// Clickable controls respond to the pointer; disabled ones stay still.
private struct HoverHighlight: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovered && isEnabled ? 0.65 : 1)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlight())
    }
}

private struct RowHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isRowHovered: Bool {
        get { self[RowHoverKey.self] }
        set { self[RowHoverKey.self] = newValue }
    }
}

/// Tells the row's copy button when the pointer is over the row. The row itself
/// doesn't change, since it isn't clickable.
private struct HoverableRow: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .environment(\.isRowHovered, isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverableRow() -> some View {
        modifier(HoverableRow())
    }
}

// MARK: - Pieces

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
                .frame(width: contactLabelColumnWidth, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
    }

    // A custom label set elsewhere stays selectable.
    private var allOptions: [String] {
        if let label, !label.isEmpty, !options.contains(label) { return [label] + options }
        return options
    }
}

/// The title of a row that has no label menu, in the same column.
struct RowTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: contactLabelColumnWidth, alignment: .leading)
    }
}

/// A text field exactly as wide as its text, so whatever follows it (the copy
/// button) sits right beside the value and moves as you type.
struct FittedTextField: View {
    @Binding var text: String
    let prompt: String
    let fieldName: String
    var lines: ClosedRange<Int> = 1...1

    var body: some View {
        // The invisible text gives the field its width.
        Text(text.isEmpty ? prompt : text)
            .lineLimit(lines)
            .hidden()
            .frame(minWidth: 44, alignment: .leading)
            .overlay {
                TextField("", text: $text, prompt: Text(prompt), axis: lines.upperBound > 1 ? .vertical : .horizontal)
                    .textFieldStyle(.plain)
                    .lineLimit(lines)
                    .accessibilityLabel(fieldName)
            }
    }
}

/// Appears beside a value when the row is hovered or focused. Copying animates the icon.
struct CopyButton: View {
    let value: String
    let fieldName: String

    @Environment(\.isRowHovered) private var isRowHovered
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var copyCount = 0
    @State private var resetTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: copy) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(isCopied ? Color.green : (isHovered ? Color.accentColor : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: copyCount)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Copy \(fieldName)")
        .accessibilityLabel("Copy \(fieldName)")
        // Always laid out, so showing it doesn't shift the row.
        .opacity(isRowHovered || isFocused || isCopied ? 1 : 0)
        .disabled(value.isEmpty)
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

private struct DeleteRowButton: View {
    let fieldName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help("Remove \(fieldName)")
        .accessibilityLabel("Remove \(fieldName)")
    }
}

// MARK: - Rows

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
            FittedTextField(text: $row.value, prompt: placeholder, fieldName: fieldName)
            CopyButton(value: row.value, fieldName: fieldName)
            Spacer(minLength: 0)
            accessory
            DeleteRowButton(fieldName: fieldName, action: onDelete)
        }
        .padding(.vertical, 8)
        // A row is as tall as its content, whatever height it's offered.
        .fixedSize(horizontal: false, vertical: true)
        .hoverableRow()
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
        HStack(alignment: .top, spacing: 8) {
            LabelMenu(label: $row.label, options: ContactLabels.address)
            VStack(alignment: .leading, spacing: 4) {
                FittedTextField(text: $row.street, prompt: "Street", fieldName: "street", lines: 1...4)
                HStack(spacing: 8) {
                    FittedTextField(text: $row.city, prompt: "City", fieldName: "city")
                    FittedTextField(text: $row.state, prompt: "State", fieldName: "state")
                    FittedTextField(text: $row.postalCode, prompt: "ZIP", fieldName: "ZIP code")
                }
                FittedTextField(text: $row.country, prompt: "Country", fieldName: "country")
            }
            CopyButton(value: row.mailingText, fieldName: "postal address")
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(action: onToggleMap) {
                    Image(systemName: isShowingMap ? "map.fill" : "map")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .disabled(row.isBlank)
                .help(isShowingMap ? "Hide Map" : "Show on Map")
                .accessibilityLabel(isShowingMap ? "Hide Map" : "Show on Map")
                DeleteRowButton(fieldName: "address", action: onDelete)
            }
        }
        .padding(.vertical, 8)
        .hoverableRow()
    }
}

/// A social profile or instant message address.
struct ServiceRow: View {
    @Binding var row: DraftService
    let kind: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RowTitle(kind)
            FittedTextField(text: $row.service, prompt: "Service", fieldName: "service")
            FittedTextField(text: $row.username, prompt: "Username", fieldName: "username")
            CopyButton(value: row.username, fieldName: kind.lowercased())
            Spacer(minLength: 0)
            DeleteRowButton(fieldName: kind.lowercased(), action: onDelete)
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .hoverableRow()
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
                RowTitle(title)
            }
            DatePicker("", selection: dateBinding, displayedComponents: .date)
                .labelsHidden()
            CopyButton(value: components.displayText, fieldName: title.lowercased())
            Toggle("Year", isOn: yearBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer(minLength: 0)
            DeleteRowButton(fieldName: title.lowercased(), action: onDelete)
        }
        .padding(.vertical, 8)
        .hoverableRow()
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
