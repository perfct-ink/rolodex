import Foundation

struct ContactChange: Codable, Identifiable, Equatable {
    var id = UUID()
    let contactID: String
    var date: Date
    let field: String
    let oldValue: String
    var newValue: String
}

/// A local log of edits made in Rolodex. Contacts doesn't keep one, and edits
/// made in other apps can't be observed, so only changes made here appear.
@MainActor
final class ContactHistoryStore: ObservableObject {
    static let shared = ContactHistoryStore()

    private static let maxEntries = 5000
    // Autosave fires while someone types; edits to one field this close
    // together read as a single change.
    private static let coalesceWindow: TimeInterval = 120

    // Oldest first.
    @Published private(set) var entries: [ContactChange]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let rolodexDir = supportDir.appendingPathComponent("Rolodex", isDirectory: true)
            try? FileManager.default.createDirectory(at: rolodexDir, withIntermediateDirectories: true)
            self.fileURL = rolodexDir.appendingPathComponent("rolodex-history.json")
        }
        if let contents = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([ContactChange].self, from: contents) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Newest first.
    func entries(for contactID: String) -> [ContactChange] {
        entries.filter { $0.contactID == contactID }.reversed()
    }

    func record(_ changes: [FieldChange], contactID: String, at date: Date = Date()) {
        guard !changes.isEmpty else { return }
        for change in changes {
            if let index = entries.lastIndex(where: { $0.contactID == contactID && $0.field == change.field }),
               date.timeIntervalSince(entries[index].date) < Self.coalesceWindow {
                if entries[index].oldValue == change.newValue {
                    entries.remove(at: index)
                } else {
                    entries[index].newValue = change.newValue
                    entries[index].date = date
                }
            } else {
                entries.append(ContactChange(
                    contactID: contactID, date: date, field: change.field,
                    oldValue: change.oldValue, newValue: change.newValue
                ))
            }
        }
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear(contactID: String) {
        entries.removeAll { $0.contactID == contactID }
        save()
    }

    private func save() {
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            print("Rolodex: failed to save history: \(error)")
        }
    }
}
