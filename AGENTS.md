# AGENTS.md — Rolodex

Rolodex is a SwiftUI macOS app (macOS 14+, Xcode 16+) for browsing and editing Contacts, with better group management: smart groups, bulk group assignment, group insights, and hidden groups. It reads and writes the real Contacts database through `CNContactStore`. App-only data (smart groups, hidden flags) is stored in `~/Library/Application Support/Rolodex/rolodex-data.json`. See [README.md](README.md).

## Commands

- `make` (`make setup dev`): check for Xcode, build Debug, and open it.
- `make test`: compile and run the contact-loading regression tests in `Tests/`, plus any Xcode test target.
- `make test-contacts`: edit a temporary contact through the real Contacts API and read it back. It needs Contacts permission; the contact is deleted afterwards.
- `make build`: Release build. `make install` / `make uninstall` / `make reinstall`: manage `/Applications`.
- `make close` / `make clean`; `make help` lists everything.

## Layout

- `Rolodex/Models/`: `SmartGroup`, `ContactDraft`, and other models.
- `Rolodex/Services/ContactsService.swift`: all `CNContactStore` access.
- `Rolodex/Persistence/`: `AppDataStore` (app-only JSON) and `ContactHistoryStore`.
- `Rolodex/ViewModels/`, `Rolodex/Views/`: MVVM UI.
- `Tests/`: standalone regression tests compiled by `make test`.

## Conventions

- New source files must be added to `Rolodex.xcodeproj` (the project doesn't use synchronized folders). If a file is needed by the regression tests, also add it to the `swiftc` file list in the `test` target of the `Makefile`.
- This app edits the user's real contacts. Never write to Contacts from tests except through `make test-contacts`, which cleans up after itself.
- Keep contact loading fast on large address books. `make test` guards against regressions.

## Design principles

Follow the [design principles](docs/rules/design-principles.md) for any UI work. Responsive layouts, consistent native components, and hover states on everything clickable (and nothing else) are the core three.

## After changing code

1. `make test`
2. `make dev`
3. Commit with a short, one-line message. `.claude/hooks/post-response.sh` runs all three, and pushes, automatically after each turn.
