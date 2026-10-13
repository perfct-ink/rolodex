import AppKit
import Contacts
import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject var viewModel: ContactsViewModel
    let contact: CNContact

    // Edits go into `draft` and are saved automatically; `baseline` is what
    // Contacts last held, so only the difference is written and recorded.
    @State private var draft: ContactDraft
    @State private var baseline: ContactDraft
    @State private var isSaving = false
    @State private var revealed: Set<ScalarField> = []
    @State private var vCardURL: URL?
    @State private var imageData: Data?
    // The address shown in the map pane, if any.
    @State private var mapAddressID: UUID?
    @State private var showingHistory = false
    @FocusState private var focusedHeaderField: HeaderField?
    // Each saved change is one undo step. A step holds the draft to return to.
    @State private var undoStack: [UndoStep] = []
    @State private var redoStack: [UndoStep] = []
    // Set while undo/redo saves, so that save isn't recorded as a new edit.
    @State private var restoreTarget: ContactDraft?

    private struct UndoStep {
        let draft: ContactDraft
        let name: String

        func adopting(_ extras: ContactDraft) -> UndoStep {
            var adopted = draft
            adopted.adoptExtras(from: extras)
            return UndoStep(draft: adopted, name: name)
        }
    }

    private static let maxUndoSteps = 100

    private enum HeaderField { case jobTitle, company }

    private enum ScalarField { case nickname, department }

    private struct ActionTarget: Identifiable {
        let id: Int
        let label: String
        let value: String

        var menuTitle: String { label.isEmpty ? value : "\(label): \(value)" }
    }

    init(contact: CNContact) {
        self.contact = contact
        let initial = ContactDraft(contact)
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                actionBar
                editableCards
                groupsCard
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let address = draft.addresses.first(where: { $0.id == mapAddressID }) {
                ContactMapPane(title: contact.displayName, address: address) {
                    withAnimation { mapAddressID = nil }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationTitle(contact.displayName)
        .focusedSceneValue(\.contactUndo, ContactUndoActions(
            undoName: undoStack.last?.name,
            redoName: redoStack.last?.name,
            undo: { Task { await undo() } },
            redo: { Task { await redo() } }
        ))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                addFieldMenu
                Button {
                    showingHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("Show Change History")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    ContactHistoryView(history: viewModel.history, contactID: contact.identifier)
                }
                if let vCardURL {
                    ShareLink(item: vCardURL) {
                        Label("Share Contact", systemImage: "square.and.arrow.up")
                    }
                }
                Menu {
                    Button(viewModel.isContactBlocked(contact.identifier) ? "Unblock Contact" : "Block Contact", role: viewModel.isContactBlocked(contact.identifier) ? nil : .destructive) {
                        viewModel.toggleBlocked(contact.identifier)
                    }
                    Divider()
                    Button("Delete Contact", role: .destructive) {
                        viewModel.selectedContactIDs = [contact.identifier]
                        viewModel.deleteSelectedContacts()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: contact) {
            vCardURL = nil
            imageData = nil
            let service = ContactsService.shared
            async let photo = try? service.fetchImageData(identifier: contact.identifier)
            async let card = try? service.exportVCardURL(identifier: contact.identifier, name: contact.displayName)
            let (loadedPhoto, loadedCard) = await (photo, card)
            guard !Task.isCancelled else { return }
            imageData = loadedPhoto
            vCardURL = loadedCard
        }
        .task(id: contact.identifier) {
            guard let loaded = try? await ContactsService.shared.fetchExtraFields(identifier: contact.identifier) else { return }
            let extras = ContactDraft(extras: loaded)
            draft.adoptExtras(from: extras)
            baseline.adoptExtras(from: extras)
            // Steps recorded before the extras arrived must not undo them away.
            undoStack = undoStack.map { $0.adopting(extras) }
            redoStack = redoStack.map { $0.adopting(extras) }
            if !extras.nickname.isEmpty { revealed.insert(.nickname) }
            if !extras.departmentName.isEmpty { revealed.insert(.department) }
        }
        // Saves shortly after typing stops.
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await commit()
        }
        .onDisappear {
            Task { await commit() }
        }
    }

    // MARK: - Autosave

    private func commit() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // Edits made during a save are picked up by the next pass.
        while draft != baseline {
            let saved = draft
            let previous = baseline
            guard await viewModel.saveContact(identifier: contact.identifier, from: previous, to: saved) else { return }
            baseline = saved
            if restoreTarget == saved {
                // Undo and redo manage the stacks themselves.
                restoreTarget = nil
                continue
            }
            let fields = previous.changes(to: saved).map(\.field)
            guard !fields.isEmpty else { continue }
            undoStack.append(UndoStep(draft: previous, name: fields.prefix(2).joined(separator: ", ")))
            if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }

    // MARK: - Undo

    // Waits out a save in flight and saves pending edits, so a step is
    // never taken against a half-saved state.
    private func settle() async {
        while isSaving { try? await Task.sleep(for: .milliseconds(50)) }
        await commit()
        while isSaving { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func undo() async {
        await settle()
        guard draft == baseline, let step = undoStack.popLast() else { return }
        let current = UndoStep(draft: baseline, name: step.name)
        redoStack.append(current)
        await restore(step.draft) {
            redoStack.removeLast()
            undoStack.append(step)
        }
    }

    private func redo() async {
        await settle()
        guard draft == baseline, let step = redoStack.popLast() else { return }
        let current = UndoStep(draft: baseline, name: step.name)
        undoStack.append(current)
        await restore(step.draft) {
            undoStack.removeLast()
            redoStack.append(step)
        }
    }

    private func restore(_ target: ContactDraft, rollback: () -> Void) async {
        restoreTarget = target
        draft = target
        await commit()
        if baseline != target {
            // The save failed and the error alert is showing; leave things as they were.
            restoreTarget = nil
            rollback()
            draft = baseline
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            avatar
                .padding(.bottom, 6)

            if draft.isCompany {
                // A company is known by its name, so that takes the title's place.
                TextField("", text: $draft.organizationName, prompt: Text("Company"))
                    .accessibilityLabel("Company")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 6) {
                    TextField("", text: $draft.givenName, prompt: Text("First Name"))
                        .accessibilityLabel("First Name")
                        .multilineTextAlignment(.trailing)
                    TextField("", text: $draft.familyName, prompt: Text("Last Name"))
                        .accessibilityLabel("Last Name")
                        .multilineTextAlignment(.leading)
                }
                .font(.system(size: 26, weight: .semibold))

                VStack(spacing: 2) {
                    TextField("", text: $draft.jobTitle, prompt: Text("Job Title"))
                        .accessibilityLabel("Job Title")
                        .focused($focusedHeaderField, equals: .jobTitle)
                        .opacity(isDimmed(draft.jobTitle, field: .jobTitle) ? 0.45 : 1)
                    TextField("", text: $draft.organizationName, prompt: Text("Company"))
                        .accessibilityLabel("Company")
                        .focused($focusedHeaderField, equals: .company)
                        .opacity(isDimmed(draft.organizationName, field: .company) ? 0.45 : 1)
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Picker("Type", selection: $draft.isCompany) {
                Label("Person", systemImage: "person.fill").tag(false)
                Label("Company", systemImage: "building.2.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .padding(.top, 6)
            .help("Whether this is a person or a company")
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    // Empty fields recede, but stay fully visible while being typed into.
    private func isDimmed(_ text: String, field: HeaderField) -> Bool {
        text.isEmpty && focusedHeaderField != field
    }

    @ViewBuilder
    private var avatar: some View {
        let size: CGFloat = 120
        if contact.imageDataAvailable,
           let data = imageData ?? contact.thumbnailImageData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: contact.posterGradient, startPoint: .top, endPoint: .bottom))
                if draft.isCompany {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: size * 0.4))
                } else {
                    Text(contact.initials)
                        .font(.system(size: size * 0.4, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
        }
    }

    // MARK: - Actions

    private var phoneTargets: [ActionTarget] {
        draft.normalized().phones.enumerated().map {
            ActionTarget(id: $0.offset, label: ContactLabel.text($0.element.label), value: $0.element.value)
        }
    }

    private var emailTargets: [ActionTarget] {
        draft.normalized().emails.enumerated().map {
            ActionTarget(id: $0.offset, label: ContactLabel.text($0.element.label), value: $0.element.value)
        }
    }

    private var actionBar: some View {
        let phones = phoneTargets
        let emails = emailTargets
        // Video calls can reach a phone number or an email address.
        let video = phones + emails.map { ActionTarget(id: phones.count + $0.id, label: $0.label, value: $0.value) }
        return HStack(spacing: 10) {
            actionButton("Message", systemImage: "message.fill", targets: phones, missing: "phone number") {
                open(scheme: "sms", target: $0)
            }
            actionButton("Call", systemImage: "phone.fill", targets: phones, missing: "phone number") {
                open(scheme: "tel", target: $0)
            }
            actionButton("Video", systemImage: "video.fill", targets: video, missing: "phone number or email") {
                open(scheme: "facetime", target: $0)
            }
            actionButton("Mail", systemImage: "envelope.fill", targets: emails, missing: "email address") {
                open(scheme: "mailto", target: $0)
            }
        }
    }

    // One target acts directly, and its tooltip says which. Several targets
    // open a menu so the choice is never made silently.
    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, targets: [ActionTarget], missing: String,
                              action: @escaping (String) -> Void) -> some View {
        if targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button(target.menuTitle) { action(target.value) }
                }
            } label: {
                actionTile(title, systemImage: systemImage)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(Color.accentColor)
            .help("Choose where to \(title.lowercased())")
        } else {
            Button {
                if let target = targets.first { action(target.value) }
            } label: {
                actionTile(title, systemImage: systemImage)
            }
            .buttonStyle(.plain)
            .foregroundStyle(targets.isEmpty ? Color.secondary.opacity(0.6) : Color.accentColor)
            .disabled(targets.isEmpty)
            .help(targets.first.map { "\(title) \($0.value)" } ?? "No \(missing)")
        }
    }

    private func actionTile(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Editable fields

    @ViewBuilder
    private var editableCards: some View {
        if !draft.phones.isEmpty {
            card {
                ForEach($draft.phones) { $row in
                    if row.id != draft.phones.first?.id { Divider() }
                    LabeledValueRow(row: $row, labels: ContactLabels.phone, placeholder: "Phone",
                                    fieldName: "phone number", onDelete: { draft.phones.removeAll { $0.id == row.id } }) {
                        phoneButtons(row.value)
                    }
                }
            }
        }

        if !draft.emails.isEmpty {
            card {
                ForEach($draft.emails) { $row in
                    if row.id != draft.emails.first?.id { Divider() }
                    LabeledValueRow(row: $row, labels: ContactLabels.email, placeholder: "Email",
                                    fieldName: "email address", onDelete: { draft.emails.removeAll { $0.id == row.id } })
                }
            }
        }

        if !draft.urls.isEmpty {
            card {
                ForEach($draft.urls) { $row in
                    if row.id != draft.urls.first?.id { Divider() }
                    LabeledValueRow(row: $row, labels: ContactLabels.url, placeholder: "URL",
                                    fieldName: "URL", onDelete: { draft.urls.removeAll { $0.id == row.id } })
                }
            }
        }

        if !draft.addresses.isEmpty {
            card {
                ForEach($draft.addresses) { $row in
                    if row.id != draft.addresses.first?.id { Divider() }
                    AddressRow(
                        row: $row, isShowingMap: mapAddressID == row.id,
                        onToggleMap: { withAnimation { mapAddressID = mapAddressID == row.id ? nil : row.id } },
                        onDelete: { draft.addresses.removeAll { $0.id == row.id } }
                    )
                }
            }
        }

        if draft.birthday != nil || !draft.dates.isEmpty {
            card {
                if draft.birthday != nil {
                    DateRow(components: Binding(get: { draft.birthday ?? DateComponents() }, set: { draft.birthday = $0 }),
                            onDelete: { draft.birthday = nil })
                }
                ForEach($draft.dates) { $row in
                    if draft.birthday != nil || row.id != draft.dates.first?.id { Divider() }
                    DateRow(title: "Date", label: $row.label, components: $row.components,
                            onDelete: { draft.dates.removeAll { $0.id == row.id } })
                }
            }
        }

        if !draft.relations.isEmpty {
            card {
                ForEach($draft.relations) { $row in
                    if row.id != draft.relations.first?.id { Divider() }
                    LabeledValueRow(row: $row, labels: ContactLabels.relation, placeholder: "Name",
                                    fieldName: "related name", onDelete: { draft.relations.removeAll { $0.id == row.id } })
                }
            }
        }

        if !draft.social.isEmpty || !draft.messaging.isEmpty {
            card {
                ForEach($draft.social) { $row in
                    if row.id != draft.social.first?.id { Divider() }
                    ServiceRow(row: $row, kind: "Social", onDelete: { draft.social.removeAll { $0.id == row.id } })
                }
                ForEach($draft.messaging) { $row in
                    if !draft.social.isEmpty || row.id != draft.messaging.first?.id { Divider() }
                    ServiceRow(row: $row, kind: "Message", onDelete: { draft.messaging.removeAll { $0.id == row.id } })
                }
            }
        }

        if !revealed.isEmpty {
            card {
                if revealed.contains(.nickname) {
                    scalarRow("Nickname", text: $draft.nickname)
                }
                if revealed.contains(.nickname) && revealed.contains(.department) { Divider() }
                if revealed.contains(.department) {
                    scalarRow("Department", text: $draft.departmentName)
                }
            }
        }
    }

    private func scalarRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            TextField("", text: text, prompt: Text(title))
                .textFieldStyle(.plain)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 8)
        .modifier(ContactFieldCopy(value: text.wrappedValue, fieldName: title.lowercased()))
    }

    private func phoneButtons(_ number: String) -> some View {
        HStack(spacing: 10) {
            Button {
                open(scheme: "sms", target: number)
            } label: {
                Image(systemName: "message.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Text \(number)")

            Button {
                open(scheme: "tel", target: number)
            } label: {
                Image(systemName: "phone.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Call \(number)")
        }
    }

    private var addFieldMenu: some View {
        let today = Calendar.current.dateComponents([.month, .day], from: Date())
        return Menu {
            Button("Phone") { draft.phones.append(DraftValue(label: ContactLabels.phone[0])) }
            Button("Email") { draft.emails.append(DraftValue(label: ContactLabels.email[0])) }
            Button("URL") { draft.urls.append(DraftValue(label: ContactLabels.url[0])) }
            Button("Address") { draft.addresses.append(DraftAddress(label: ContactLabels.address[0])) }
            if draft.birthday == nil {
                Button("Birthday") { draft.birthday = today }
            }
            Button("Date") { draft.dates.append(DraftDate(label: ContactLabels.date[0], components: today)) }
            Button("Related Name") { draft.relations.append(DraftValue(label: ContactLabels.relation[0])) }
            Button("Social Profile") { draft.social.append(DraftService()) }
            Button("Instant Message") { draft.messaging.append(DraftService()) }
            if !revealed.contains(.nickname) {
                Button("Nickname") { revealed.insert(.nickname) }
            }
            if !revealed.contains(.department) {
                Button("Department") { revealed.insert(.department) }
            }
        } label: {
            Label("Add Field", systemImage: "plus")
        }
        .help("Add Field")
    }

    // MARK: - Cards

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var groupsCard: some View {
        let memberGroups = viewModel.groups.filter { viewModel.membership[contact.identifier]?.contains($0.identifier) == true }
        let remainingGroups = viewModel.groups.filter { !(viewModel.membership[contact.identifier]?.contains($0.identifier) ?? false) }
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if memberGroups.isEmpty && remainingGroups.isEmpty {
                    Text("No groups available").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(memberGroups, id: \.identifier) { group in
                            groupTag(group)
                        }
                        if !remainingGroups.isEmpty {
                            addGroupTag(remainingGroups)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func groupTag(_ group: CNGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
                .font(.caption)
            Button {
                viewModel.setMembership(false, contactIDs: [contact.identifier], group: group)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }

    private func addGroupTag(_ remainingGroups: [CNGroup]) -> some View {
        Menu {
            ForEach(remainingGroups, id: \.identifier) { group in
                Button(group.name) {
                    viewModel.setMembership(true, contactIDs: [contact.identifier], group: group)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func open(scheme: String, target: String) {
        // Phone numbers are reduced to digits; email addresses (mail, or FaceTime to an email) are kept.
        let isAddress = scheme == "mailto" || target.contains("@")
        let cleaned = isAddress ? target : target.filter { $0.isNumber || $0 == "+" }
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleaned
        guard let url = URL(string: "\(scheme):\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct NewContactSheet: View {
    @EnvironmentObject var viewModel: ContactsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var givenName = ""
    @State private var familyName = ""
    @State private var organizationName = ""
    @State private var selectedGroupIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Contact").font(.title2).bold()
            Form {
                TextField("First Name", text: $givenName)
                TextField("Last Name", text: $familyName)
                TextField("Company", text: $organizationName)
                if !viewModel.groups.isEmpty {
                    Section("Add to Groups") {
                        ForEach(viewModel.groups, id: \.identifier) { group in
                            Toggle(group.name, isOn: Binding(
                                get: { selectedGroupIDs.contains(group.identifier) },
                                set: { isOn in
                                    if isOn { selectedGroupIDs.insert(group.identifier) } else { selectedGroupIDs.remove(group.identifier) }
                                }
                            ))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let mutable = CNMutableContact()
                    mutable.givenName = givenName
                    mutable.familyName = familyName
                    mutable.organizationName = organizationName
                    let groups = viewModel.groups.filter { selectedGroupIDs.contains($0.identifier) }
                    viewModel.createContact(mutable, groups: groups)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(givenName.isEmpty && familyName.isEmpty && organizationName.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
