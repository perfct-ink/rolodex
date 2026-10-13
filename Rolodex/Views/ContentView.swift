import Contacts
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ContactsViewModel

    var body: some View {
        Group {
            if viewModel.authorizationDenied {
                PermissionDeniedView()
            } else if viewModel.isLoading && viewModel.contacts.isEmpty {
                LoadingView()
            } else {
                mainSplitView
            }
        }
        .task {
            await viewModel.start()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var mainSplitView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } content: {
            Group {
                if viewModel.selection == .insights {
                    GroupInsightsView()
                } else {
                    ContactListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if viewModel.selection == .insights {
            ContentUnavailableView(
                "Group Insights",
                systemImage: "chart.bar.fill",
                description: Text("Explore your groups using the panel on the left.")
            )
        } else if viewModel.selectedContactIDs.count == 1,
                  let identifier = viewModel.selectedContactIDs.first,
                  let contact = viewModel.contactsByID[identifier] {
            ContactDetailView(contact: contact)
                .id(contact.identifier)
        } else if viewModel.selectedContactIDs.count > 1 {
            ContentUnavailableView(
                "\(viewModel.selectedContactIDs.count) Contacts Selected",
                systemImage: "person.2.crop.square.stack",
                description: Text("Drag them onto a group in the sidebar to add them.")
            )
        } else {
            ContentUnavailableView(
                "No Contact Selected",
                systemImage: "person.crop.circle",
                description: Text("Select a contact to view details.")
            )
        }
    }
}
