# Rolodex

A native macOS app for browsing and editing your Contacts, with better group
management than Apple's Contacts app: smart (rule-based) groups, bulk
multi-group assignment, group insights (empty groups, ungrouped contacts,
overlapping groups you might want to merge), and the ability to hide certain
groups' members from the main "All Contacts" view.

It reads and writes your real macOS Contacts via the Contacts framework
(`CNContactStore`) — there is no separate database for your contacts. Smart
group definitions and the hidden/blocked flags are app-only concepts (the
Contacts framework has no API for them), so those are stored locally in
`~/Library/Application Support/Rolodex/rolodex-data.json`.

## Requirements

- Xcode 16 or later (this project was authored by hand outside Xcode, since
  only the Command Line Tools were available in the environment that
  generated it — open it in Xcode before doing anything else so Xcode can
  verify/upgrade the project file).
- macOS 14 (Sonoma) or later, both to build and to run.

## Getting started

1. Open `Rolodex.xcodeproj` in Xcode.
2. Select the `Rolodex` target → **Signing & Capabilities** and set your own
   Team (a free personal team is fine for local use). You can leave the
   bundle identifier (`org.perfectink.rolodex`) as-is unless Xcode flags a
   conflict.
3. Build and run (⌘R). On first launch, macOS will prompt for Contacts
   access — approve it. If you ever deny it, the app shows a button that
   deep-links to System Settings → Privacy & Security → Contacts.

## Notes on scope

The app version and build number are defined in `VERSION` at the
repository root. Edit `MARKETING_VERSION` (for example, `1.1`) and
`CURRENT_PROJECT_VERSION` (for example, `2`) there. Both Debug and Release
builds use these values for the app's `Info.plist`.

- **Notes field**: contact notes are intentionally not read/edited. Apple
  restricts `CNContactNoteKey` to apps with a special, Apple-granted
  entitlement — without it, simply including that key in a fetch throws at
  runtime for every contact.
- **Block Contact**: this only tags a contact as "blocked" inside Rolodex's
  own local data — there is no public API for a third-party app to block
  calls/texts at the OS level. Real call/message blocking requires a
  separate CallKit call-directory extension, which is a much bigger,
  separate feature.
- **Merging groups**: moves all members of the source group into the
  destination group, then deletes the source group.
