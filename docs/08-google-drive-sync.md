# Google Drive sync

Margins supports optional, local-first cloud sync using Google Drive. Documents remain plain `.margins` files in `~/Documents/Margins/` so typing, autosave, and history previews stay instant and never block on the network; a background engine syncs changes asynchronously to a visible `Margins` folder in your Google Drive.

## Connecting Google Drive

Packaged releases (`Margins.app` / DMG) bundle Margins' Google Desktop OAuth client credentials in `Info.plist` (`MarginsGoogleClientID` and `MarginsGoogleClientSecret`), so sign-in takes one click:

1. Open **Settings → Sync** (or click **Connect Google Drive…** in the first-run onboarding banner).
2. Click **Connect Google Drive…**. Margins opens your browser for Google's OAuth 2.0 consent screen using PKCE (S256) and a local `127.0.0.1` loopback callback server.
3. Grant access to the `https://www.googleapis.com/auth/drive.file` scope.
4. If `~/Documents/Margins/` already contains documents, Margins prompts whether to upload them to the Drive `Margins` folder (deduplicating by document UUID).

Tokens are stored in your macOS login Keychain under service `com.vivekhaldar.margins` (account `googleDriveOAuthTokens`). Disconnecting revokes the token with Google and clears it from Keychain while keeping all local files intact.

### Narrow scope, production OAuth status, and Drive folder

Margins requests only `https://www.googleapis.com/auth/drive.file`, which limits access to the `Margins` folder and files Margins itself creates. It cannot read or list the rest of your Google Drive. The `Margins` folder is a normal visible folder tagged with `appProperties`, so you can inspect, back up, or move it in Drive without breaking sync.

The bundled Google OAuth client is configured with an **External** audience and **In production** publishing status, so any Google account can authorize Drive sync without joining a test-user list, and refresh tokens are free of Google's 7-day Testing-mode expiration limit. Google's Verification Center requires no additional data-access review for `drive.file`; brand verification is optional for public sign-in and only controls whether Google displays the Margins name and logo on the consent screen.

## How sync works

- **Identity by UUID, not filename:** Each `.margins` document carries a stable UUID (`doc.id`). Drive files store `appProperties: { "marginsDocId": "<uuid>" }`, and Margins maintains a local index at `~/Library/Application Support/Margins/sync-index.json` mapping `doc.id ↔ driveFileId`, `lastSyncedRevision`, and `localPath`. Auto-renaming `Untitled.margins` to `<Title>.margins` updates the Drive file metadata in place instead of creating duplicates.
- **Background pushes and delta pulls:** Local autosaves schedule a 3-second debounced upload, and quitting flushes pending pushes. Incremental pulls use Drive's `changes.list` with a saved `startPageToken` on launch, whenever the app regains focus, and every 45 seconds while active.
- **Offline queue:** Edits made while offline are queued locally and uploaded automatically once connectivity returns.
- **External file watcher:** `FileChangeWatcher` monitors open `.margins` files for atomic-write updates from sync (or external tools), ignores Margins' own saves, and reloads open windows when remote changes arrive.
- **Markdown regeneration:** When a remote `.margins` update is pulled, Margins regenerates the sibling `<Title>.md` and `<Title>.assets/` mirror locally.

## What syncs vs. what stays local

| Artifact | Location | Sync behavior |
|---|---|---|
| `.margins` file (HTML, intents, threads, versions, assets, annotations) | `~/Documents/Margins/` | **Synced** to Google Drive `Margins/` folder. |
| Project folder mapping (`doc.id → projectFolder`) | Local `ProjectFolderStore` (`UserDefaults`) | **Per-machine.** Local repository paths differ across Macs, so one Mac never overwrites another's project path. Legacy `doc.projectFolder` fields migrate automatically on open. |
| `<Title>.md` and `<Title>.assets/` | Next to `.margins` | **Regenerated locally** on save and pull. |
| Agent scratch workspace | `~/Library/Application Support/Margins/Workspaces/<id>/` | **Local only.** |
| App preferences & provider credentials | `UserDefaults` / Keychain / vendor CLIs | **Local only.** |

## Conflict resolution

Before uploading, Margins compares Drive's `headRevisionId` with `lastSyncedRevision`. If another Mac updated the document while you edited offline, Margins downloads the remote version and writes your divergent local copy alongside it as:

```
<Title> (Conflict on <Mac> <date>).margins
```

A conflict banner appears in the editor window so neither version is lost and you can compare or keep what you need.

## Opening files and toolbar status

- **Library picker (`⌘O`):** When Google Drive sync is connected, `⌘O` opens an in-app library picker backed by `sync-index.json`, sorted by recency with instant title search and sync badges (*Synced*, *Syncing*, *Cloud-only*, *Conflict*, *Local*). Cached files open immediately; cloud-only files download on demand.
- **Open from Disk (`⇧⌘O`):** Opens the standard macOS file panel to open any `.margins` file outside `~/Documents/Margins/` (for example, inside a Git repo). External files stay local-only.
- **Toolbar sync pill:** Displays current sync state (*Synced*, *Syncing…*, *Offline*, or *Conflict*) with a popover showing the last-synced time and a **Sync Now** action.

## Custom OAuth client (source builds and self-hosters)

Unpackaged builds (`swift run Margins`) and source builds run without `MARGINS_GOOGLE_OAUTH_FILE` or `pass` do not embed a bundled OAuth client. To test or run sync in those builds—or to use an internal Google Workspace OAuth client:

1. Create a **Desktop app** OAuth 2.0 client in Google Cloud Console with the Google Drive API enabled.
2. Either inject it at build time via `MARGINS_GOOGLE_OAUTH_FILE=/path/to/desktop-oauth.json scripts/build-app.sh`, or enter the Client ID and Client Secret in **Settings → Sync → Use a custom Google OAuth client**.

Custom client secrets are stored in your login Keychain (`googleDriveOAuthClientSecret`), not `UserDefaults`. A custom Client ID never inherits the bundled client secret.

## Architecture and verification

Core sync components live in `Sources/MarginsCore/Sync/`:

- `SyncBackend.swift` — pluggable `SyncBackend` protocol (list changes, upload, download, delete) so additional backends can be added without changing the editor.
- `GoogleOAuth.swift` — RFC 7636 S256 PKCE, `127.0.0.1` loopback callback server, token refresh/revocation, Keychain token store, and `GoogleOAuthConfig.usingDefault(_:)`.
- `GoogleDriveBackend.swift` — Google Drive REST v3 client (`drive.file`, `appProperties`, `changes.list`, pagination, 401 token refresh retry).
- `SyncIndex.swift` & `SyncEngine.swift` — persistent index, library scan, deduplication, debounced push, conflict-copy creation, offline queue, and on-demand download.

App integration lives in `Sources/Margins/SyncController.swift`, `LibraryPickerView.swift`, `SettingsView.swift`, `ProjectFolderStore.swift`, and `FileChangeWatcher.swift`.

Run the self-test suite (which covers PKCE, loopback OAuth sockets, token refresh/revocation, Drive API pagination/401 retry, `SyncIndex`, `SyncEngine`, `ProjectFolderStore`, `FileChangeWatcher`, and bundled-client fallback):

```sh
swift run MarginsSelfTest
```
