import Contacts
import SwiftUI

struct ContactListView: View {
    @EnvironmentObject var viewModel: ContactsViewModel
    @State private var isPresentingNewContact = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            List(selection: $viewModel.selectedContactIDs) {
                ForEach(viewModel.visibleContacts, id: \.identifier) { contact in
                    ContactRowView(contact: contact)
                        .tag(contact.identifier)
                        .draggable(dragPayload(for: contact))
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isPresentingNewContact = true
                } label: {
                    Label("New Contact", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
        .sheet(isPresented: $isPresentingNewContact) {
            NewContactSheet()
        }
        .overlay {
            if viewModel.visibleContacts.isEmpty {
                ContentUnavailableView(
                    "No Contacts",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(viewModel.searchText.isEmpty ? "This group has no contacts yet." : "No contacts match your search.")
                )
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                filterChip("All", isSelected: viewModel.selection == .allContacts) {
                    viewModel.selection = .allContacts
                }
                filterChip(SmartGroup.builtInPeople.name, isSelected: viewModel.selection == .smartGroup(SmartGroup.builtInPeopleID)) {
                    viewModel.selection = .smartGroup(SmartGroup.builtInPeopleID)
                }
                filterChip(SmartGroup.builtInCompanies.name, isSelected: viewModel.selection == .smartGroup(SmartGroup.builtInCompaniesID)) {
                    viewModel.selection = .smartGroup(SmartGroup.builtInCompaniesID)
                }
                ForEach(viewModel.smartGroups) { smartGroup in
                    filterChip(smartGroup.name, isSelected: viewModel.selection == .smartGroup(smartGroup.id)) {
                        viewModel.selection = .smartGroup(smartGroup.id)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch viewModel.selection {
        case .allContacts:
            return "All Contacts"
        case .group(let id):
            return viewModel.groups.first { $0.identifier == id }?.name ?? "Group"
        case .smartGroup(let id):
            return viewModel.smartGroup(withID: id)?.name ?? "Smart Group"
        case .insights:
            return "Insights"
        }
    }

    private func dragPayload(for contact: CNContact) -> String {
        if viewModel.selectedContactIDs.contains(contact.identifier), viewModel.selectedContactIDs.count > 1 {
            return viewModel.selectedContactIDs.joined(separator: "\n")
        }
        return contact.identifier
    }
}
