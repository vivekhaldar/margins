<img src="assets/AppIcon.png" width="128" alt="Margins icon">

# Margins

**Write by refining, not chatting.**

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
- **Tracked changes.** Agent edits show up as inline insertions and deletions. You can review them in several ways:
  - one at a time: ✓ / ✕, or the keys `A` / `R`;
  - by instruction: "Accept these";
  - by selection: ⌘-click or `X`, then accept or reject the selected ones;
  - all at once.
- **💬 Refine a single change.** Ask the agent to redo just that hunk ("shorter", "more formal"…) without touching the rest of the document.
- **Discuss a selection inline.** Select some text and click **Ask** (or press ⌘J) to open a comment thread beside that passage. Ask questions ("is this accurate?", "explain this") and the agent answers in the thread without touching the text. Ask for a change ("tighten this") and it edits just that passage as tracked changes, with a one-line note in the thread. Threads stay as 💬 markers in the margin, so you can reopen and continue them, and each message also appears as a card in the left panel.
- **Edit inline.** The document is plain editable rich text. Your edits are respected and recorded.
- **Images and diagrams.** Ask for one ("add a diagram of the request flow"), and the agent draws it as SVG; it can revise it later like any other text. Paste or drag in images, or use Insert → Image… (⇧⌘I). Images are stored inside the `.margins` file, once each, no matter how many versions reference them.
- **Links.** ⌘K links the selection (or edits the link under the caret), and pasting a URL over selected text links it. Click a link for Open ↗ / Edit / Remove; ⌘-click opens it in your browser.
- **Outline.** A map of the headings sits beside the page. Click a heading to jump to it; the current section is highlighted, and dots mark sections with pending changes. When the window is narrow it shrinks to a strip of ticks on the right edge that expands on hover. Toggle it with ⌃⌘O or the toolbar button ([mock](docs/mocks/outline.html)).
- **History.** Every version gets a short slug ("add summary at top"), an author (agent / you / review) and the instruction that produced it. You can preview or restore any version.
- **A real agent behind the page.** The backend is a full agent, not a one-shot completion. It can reason, search the web, fetch pages, read files and (if you allow it) run commands before writing its edit. Each tool call streams live onto the instruction card, so you can watch what it's doing. Stop a run with the card's Stop button or ⌘. See [Agent tools](#agent-tools).
- **YouTube links just work.** Paste a YouTube URL into an instruction ("summarize this talk: https://youtu.be/…"), and Margins fetches the video's transcript itself and hands it to the agent, with any provider and at any tool level.
- **Bring your own subscription.** Margins uses the model access you already pay for. See [Model providers](#model-providers).

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

### Agent tools

Pick a tool level from the model menu in the toolbar or from the **Agent → Tools** menu. The setting is remembered.

| Level | What the agent may do |
|---|---|
| **Off** | Answer from the document only (one-shot). |
| **Research** (default) | Search the web, fetch pages and read files freely. Copilot **asks you inline** (Allow / Allow all / Deny) before running a command or writing a file. Codex and Claude just aren't given those tools. |
| **Full agent** | Run commands, write files and use the network inside the document's workspace, without asking. |

Each document has its own agent workspace at `~/Library/Application Support/Margins/Workspaces/<doc-id>/`, where the agent can keep scratch files across instructions (Agent → Reveal Agent Workspace). Margins also fetches some sources itself, before the agent starts: currently the transcript of any YouTube video linked in the instruction, which agents can't reliably get on their own. Whatever the agent does, its final answer is still an edit plan, so every change arrives as a tracked change for you to review. The OpenAI-compatible provider is always one-shot.

Command-line equivalent: `swift run margins-cli edit copilot --tools research --yes "summarize https://…"` (`--yes` auto-approves permission asks).

## Docs

1. [Motivation](docs/01-motivation.md): why not turn-based chat.
2. [Design journey](docs/02-design-journey.md): from three mockups to tracked changes ([mocks](docs/mocks/index.html)).
3. [Model providers](docs/03-model-providers.md): using Copilot, ChatGPT and Claude subscriptions, and agent mode.
4. [Architecture](docs/04-architecture.md): code layout, edit plans, block model, file format.
5. [Roadmap](docs/05-roadmap.md).
