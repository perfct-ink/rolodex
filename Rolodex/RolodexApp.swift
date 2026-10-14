import SwiftUI

@main
struct RolodexApp: App {
    @StateObject private var viewModel = ContactsViewModel()

    // `make test-contacts` launches a Debug build with this flag to test against the real Contacts API.
    private static var isContactsSelfTest: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--contacts-selftest")
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if Self.isContactsSelfTest {
                Text("Running Contacts self-test…")
                    .frame(width: 320, height: 120)
                    .task {
                        #if DEBUG
                        await ContactsSelfTest.runAndExit()
                        #endif
                    }
            } else {
                ContentView()
                    .environmentObject(viewModel)
                    .frame(minWidth: 920, minHeight: 600)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) { UndoRedoCommands() }
        }
    }
}
