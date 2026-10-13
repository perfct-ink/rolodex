import SwiftUI

struct ContactHistoryView: View {
    @ObservedObject var history: ContactHistoryStore
    let contactID: String

    var body: some View {
        let entries = history.entries(for: contactID)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    history.clear(contactID: contactID)
                }
                .disabled(entries.isEmpty)
            }
            .padding(12)

            Divider()

            if entries.isEmpty {
                Text("Changes you make in Rolodex will appear here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(entries) { entry in
                    entryRow(entry)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 360, height: 400)
    }

    private func entryRow(_ entry: ContactChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.field)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            valueText(entry.oldValue)
                .strikethrough(!entry.oldValue.isEmpty)
                .foregroundStyle(.secondary)
            valueText(entry.newValue)
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private func valueText(_ value: String) -> Text {
        value.isEmpty ? Text("(empty)").italic() : Text(value)
    }
}
