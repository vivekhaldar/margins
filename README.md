<img src="assets/AppIcon.png" width="128" alt="Margins icon">

# Margins

**Write by refining, not chatting.**

[Download for macOS](https://github.com/vivekhaldar/margins/releases/latest) · [Documentation](#docs) · [Apache 2.0 license](LICENSE)

Margins is a native macOS app for working with an AI agent on a document. You don't trade chat messages with it. On the left you type instructions in natural language. On the right is the document, which the agent edits as **tracked changes**. You accept, reject or refine each change, and you can always type into the document yourself.

The output isn't a reply. It's the document.

```
┌ Instructions ────────────┐┌ Document ──────────────────────────────┐
│ ① Draft a design note…   ││  Design Note: Rate Limiting            │
│   applied · Copilot      ││                                        │
│ ② Add a summary at top   ││ ▌Summary                     ✓ ✕ 💬    │
│   1 pending              ││ ▌We propose per-key limits…            │
│   [Accept these] [Reject]││                                        │
│                          ││  Problem                               │
│ > tighten the prose…     ││  Our public REST API has no…           │
└──────────────────────────┘└────────────────────────────────────────┘
```

## Features

- **Instructions, not turns.** Each instruction becomes a card that shows its status, the agent's one-line summary and any assumptions the agent made. Select some text first to scope an instruction to it.
- **Send a paragraph as a prompt.** Put the cursor in a document paragraph and press ⌘Enter to turn it from a rough prompt into a clean, synthesized answer that fits the document. The agent replaces the prompt in place as a tracked change, so you can accept the answer or reject it to keep your original prompt. In the instruction pane, Enter or ⌘Enter sends the draft, and Shift-Enter adds a newline.
- **Tracked changes.** Agent edits show up as inline insertions and deletions, including the first draft. For a first draft, accept keeps the generated text and reject returns to an empty document. You can review changes in several ways:
  - one at a time: ✓ / ✕, or the keys `A` / `R`;
  - by instruction: "Accept these";
  - by selection: ⌘-click or `X`, then accept or reject the selected ones;
  - all at once.
- **💬 Refine a single change.** Ask the agent to redo just that hunk ("shorter", "more formal"…) without touching the rest of the document.
- **Discuss a selection inline.** Select some text and click **Ask** (or press ⌘J) to open a comment thread beside that passage. Ask questions ("is this accurate?", "explain this") and the agent answers in the thread without touching the text. Ask for a change ("tighten this") and it edits just that passage as tracked changes, with a one-line note in the thread. Threads stay as 💬 markers in the margin, so you can reopen and continue them, and each message also appears as a card in the left panel.
- **Attribution and local comments.** Enable **Attribution & comments** to inspect the instruction and recorded activity behind agent text. Select text to add a personal comment without calling an agent; reply, resolve, or reattach it later. Mixed origins and comments survive review, saving, reopening, and version history. The overlay starts hidden; capture continues. [Usage and verification](docs/07-annotations.md).
- **Edit inline.** The document is plain editable rich text. Your edits are respected and recorded.
- **Images and diagrams.** Ask for one ("add a diagram of the request flow"), and the agent draws it as SVG; it can revise it later like any other text. Paste or drag in images, or use Insert → Image… (⇧⌘I). Images are stored inside the `.margins` file, once each, no matter how many versions reference them.
- **Links.** ⌘K links the selection (or edits the link under the caret), and pasting a URL over selected text links it. Click a link for Open ↗ / Edit / Remove; ⌘-click opens it in your browser.
- **Format text.** Use the formatting toolbar or the Format menu: bold (⌘B), italic (⌘I), underline (⌘U), bulleted lists (⇧⌘8), numbered lists (⇧⌘7), and checklists (⇧⌘9). Click a checkbox or press ⇧⌘X to toggle the current task; selecting several tasks toggles them together. Clear inline formatting with ⌥⌘0. Checkbox state is saved with the document and exported as Markdown task lists.
- **Find in the document.** ⌘F opens search and highlights every match, with a match count and a stronger highlight for the current result. Enter / Shift-Enter or ⌘G / ⇧⌘G move between matches; Esc closes search. Search is case-insensitive and includes visible tracked changes and history previews.
- **Outline.** A map of the headings sits beside the page. Click a heading to jump to it; the current section is highlighted, and dots mark sections with pending changes. When the window is narrow it shrinks to a strip of ticks on the right edge that expands on hover. Toggle it with ⌃⌘O or the toolbar button ([mock](docs/mocks/outline.html)).
- **Zoom the interface.** ⌘+ (or ⌘=) and ⌘− resize the active document window's instructions, composer, document, outline, editor controls, toolbar, and history together. ⌘0 returns to actual size. Zoom ranges from 50% to 300%; new windows inherit the last saved level.
- **Restore open windows.** Quitting and reopening Margins restores every open document, window position and size, minimized state, and the active document. Windows you close before quitting stay closed. Empty windows are saved too; missing or unreadable documents are skipped.
- **History.** Every version gets a short slug ("add summary at top"), an author (agent / you / review) and the instruction that produced it. You can preview or restore any version.
- **A real agent behind the page.** The backend is a full agent, not a one-shot completion. It can reason, search the web, fetch pages, read files and (if you allow it) run commands before writing its edit. Each tool call streams live onto the instruction card, so you can watch what it's doing. Stop a run with the card's Stop button or ⌘. See [Agent tools](#agent-tools).
- **Code and write in your project.** Point a document at a project folder (the 📁 toolbar menu, or Agent → Project Folder… ⇧⌘P) and the agent works *in that folder*: select a TODO and say "implement this", and it changes the code, runs the build and tests, and reports back. Files it touched are listed on the card ("Changed 2 files", click to open) and in the thread, and the document is only edited if you ask. Use **Full agent** tools for this (Margins offers to switch when you pick a folder); with Research, Copilot asks before each change and Codex/Claude can only read.
- **YouTube links just work.** Paste a YouTube URL into an instruction ("summarize this talk: https://youtu.be/…"), and Margins fetches the video's transcript itself and hands it to the agent, with any provider and at any tool level.
- **Bring your own subscription.** Margins uses the model access you already pay for. See [Model providers](#model-providers).

## Install

Download the latest DMG from [GitHub Releases](https://github.com/vivekhaldar/margins/releases/latest), open it, and drag **Margins** into **Applications**. The initial release requires **macOS 14 or later on Apple silicon**. A model provider is configured separately; see [Model providers](#model-providers).

The app is ad-hoc signed, not Apple-notarized. macOS may block the first launch. If you trust the download, try opening it, then use **System Settings → Privacy & Security → Open Anyway**. Release assets include a SHA-256 checksum and a source snapshot for the packaged build.

## Quick start

1. Install and sign in to a supported provider CLI, or configure an OpenAI-compatible endpoint in **Settings** (⌘,).
2. Choose your provider and model in the toolbar.
3. Enter an instruction such as “Draft a short design note about rate limiting.” Review the tracked changes, then accept or reject them.
4. Keep refining in the instruction pane, or write a rough prompt in the document and press ⌘Enter.

Open another document window with **⇧⌘N**. Documents autosave, and open windows are restored when the app restarts.

## Build and run

You need macOS 14+ and the Swift 5.10+ toolchain. The Command Line Tools are enough; Xcode is not required.

```sh
scripts/build-app.sh --open      # release build → build/Margins.app, then launch
```

For development:

```sh
swift build --product Margins && swift run Margins   # run unpackaged
swift run MarginsSelfTest                            # core-logic checks
swift run margins-cli models copilot                 # list models via a provider
swift run margins-cli edit copilot "Draft a haiku about tracked changes"
swift run margins-cli edit copilot --blocks blocks.json --quote "some text" "Is this accurate?"   # inline discussion
swift scripts/make-icon.swift                        # resize assets/AppIcon-source.png → AppIcon.png + AppIcon.icns
```

> `swift test` and SwiftUI's `@State` macro both need plugins that ship only with Xcode. The project avoids them: the tests are a self-test executable, and view-local state uses a tiny `Local<T>` ObservableObject.

Documents autosave to `~/Documents/Margins/<Title>.margins`, which is JSON and includes the full version history. A plain `<Title>.md` beside it is kept in sync with the current accepted text, with images in `<Title>.assets/` (File → Show Markdown in Finder). Use ⌘O to open, ⇧⌘S to save a copy elsewhere, and ⇧⌘E to export HTML. ⌘+ / ⌘− / ⌘0 zoom the document; the zoom level is remembered.

## Model providers

| Provider | Uses | Sign in with |
|---|---|---|
| **GitHub Copilot** (default) | `copilot --acp` (Agent Client Protocol over stdio) | `copilot` → `/login` |
| **ChatGPT / Codex** | `codex exec --output-schema …` | `codex login` (ChatGPT plan) |
| **Claude Code** | `claude -p --json-schema …` | `claude` → `/login` (Claude plan) |
| **OpenAI-compatible** | HTTP `/v1/chat/completions` | API key (Keychain), or none for Ollama / LM Studio |

Margins drives each vendor's own CLI, so your subscription is used exactly as the vendor intends. Margins never sees or stores those credentials. Choose the provider and model from the toolbar; configure providers in **Settings** (⌘,).

Why it works this way: [docs/03-model-providers.md](docs/03-model-providers.md).

For **ChatGPT / Codex**, open the model menu and choose **Reasoning effort**: Default (inherit the Codex configuration), Low, Medium, High, Extra high, Max, or Ultra. Supported levels depend on your model and installed Codex version; use Default if an explicit level is rejected. The choice is saved per provider and applies to new edits, paragraph prompts, discussions, and refinements. Explicit effort appears beside the model in the toolbar. You can also change it in **Settings → Providers**. Other backends do not yet expose effort selection in Margins.

### Agent tools

Pick a tool level from the model menu in the toolbar or from the **Agent → Tools** menu. The setting is remembered.

| Level | What the agent may do |
|---|---|
| **Off** | Answer from the document only (one-shot). |
| **Research** (default) | Search the web, fetch pages and read files freely. Copilot **asks you inline** (Allow / Allow all / Deny) before running a command or writing a file. Codex and Claude just aren't given those tools. |
| **Full agent** | Run commands, write files and use the network inside the document's workspace (or project folder), without asking. |
| **Unrestricted** | No sandbox: act anywhere on your Mac — install tools under `~`, edit config files, ssh to your servers. The agent is told never to use `sudo` or delete things it wasn't asked to. Use deliberately. |

Each document has its own agent workspace at `~/Library/Application Support/Margins/Workspaces/<doc-id>/`, where the agent can keep scratch files across instructions (Agent → Reveal Agent Workspace). If you set a **project folder** for the document, the agent works there instead and may change your files (with Full agent tools). It is told not to commit or push unless asked; in a git repo, Margins lists the files each run changed. Margins also fetches some sources itself, before the agent starts: currently the transcript of any YouTube video linked in the instruction, which agents can't reliably get on their own. Whatever the agent does, its final answer is still an edit plan, so every change arrives as a tracked change for you to review. The OpenAI-compatible provider is always one-shot.

Command-line equivalent: `swift run margins-cli edit copilot --tools research --yes "summarize https://…"` (`--yes` auto-approves permission asks). Add `--project DIR` to let the agent work in a project folder, e.g. `margins-cli edit codex --tools full --project ~/src/app "fix the failing test"`.

## Docs

1. [Motivation](docs/01-motivation.md): why not turn-based chat.
2. [Design journey](docs/02-design-journey.md): from three mockups to tracked changes ([mocks](docs/mocks/index.html)).
3. [Model providers](docs/03-model-providers.md): using Copilot, ChatGPT and Claude subscriptions, and agent mode.
4. [Architecture](docs/04-architecture.md): code layout, edit plans, block model, file format.
5. [Roadmap](docs/05-roadmap.md).
6. [Attribution and comments](docs/07-annotations.md): usage, storage rules, and verification.


## Contributing

Bug reports and focused pull requests are welcome through [GitHub Issues](https://github.com/vivekhaldar/margins/issues) and pull requests. Include your macOS version, provider, and steps to reproduce a bug; remove private document text and credentials from logs.

For code changes, build the app and run `swift run MarginsSelfTest`. Editor changes can also be checked with `swift scripts/test-editor-find.swift` and `swift scripts/test-editor-paragraph.swift`, and `swift scripts/test-editor-format.swift`.

### Linux orbs

Amp runs `.agents/setup` when preparing an orb snapshot. It ensures Node.js 18+ is
available and runs the dependency-free editor alignment checks. A warm setup reuses
the installed toolchain without package downloads; exact snapshot matches skip setup.
`.agents/resume` only checks Node.js on activation and wake-up. There are no package
dependencies, databases, required secrets, or provider logins for these checks.

```sh
node scripts/test-annotation-alignment.js
```

Linux orbs are useful for editor JavaScript, documentation, and static-site work.
The Swift package cannot build on Linux: the app uses SwiftUI/AppKit/WebKit, and even
`MarginsCore` uses Apple's Security and CryptoKit frameworks. Setup deliberately does
not download a Linux Swift compiler. App builds, `MarginsSelfTest`, packaging, and the
Swift-based editor integration checks still require a Mac with macOS 14+ and Swift
5.10+. Chromium editor inspection in an orb is not a substitute for WKWebView tests.

## Packaging a release

```sh
MARGINS_VERSION=0.2.0 scripts/build-dmg.sh
```

This builds a release app, packages it with an Applications shortcut, README and license, and writes a DMG plus a SHA-256 checksum under `build/`. Set `MARGINS_BUILD_NUMBER` to override the numeric bundle build number. The script builds for the host architecture; it does not notarize or publish the result. Publish the DMG, checksum and matching source snapshot through [GitHub Releases](https://github.com/vivekhaldar/margins/releases).

## License

Copyright 2026 Vivek Haldar. Licensed under the [Apache License, Version 2.0](LICENSE).
