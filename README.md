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
- **Edit inline.** The document is plain editable rich text. Your edits are respected and recorded.
- **Links.** ⌘K links the selection (or edits the link under the caret), and pasting a URL over selected text links it. Click a link for Open ↗ / Edit / Remove; ⌘-click opens it in your browser.
- **History.** Every version gets a short slug ("add summary at top"), an author (agent / you / review) and the instruction that produced it. You can preview or restore any version.
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
```

> `swift test` and SwiftUI's `@State` macro both need plugins that ship only with Xcode. The project avoids them: the tests are a self-test executable, and view-local state uses a tiny `Local<T>` ObservableObject.

Documents autosave to `~/Documents/Margins/<Title>.margins`, which is JSON and includes the full version history. A plain `<Title>.md` beside it is kept in sync with the current accepted text (File → Show Markdown in Finder). Use ⌘O to open, ⇧⌘S to save a copy elsewhere, and ⇧⌘E to export HTML. ⌘+ / ⌘− / ⌘0 zoom the document; the zoom level is remembered.

## Model providers

| Provider | Uses | Sign in with |
|---|---|---|
| **GitHub Copilot** (default) | `copilot --acp` (Agent Client Protocol over stdio) | `copilot` → `/login` |
| **ChatGPT / Codex** | `codex exec --output-schema …` | `codex login` (ChatGPT plan) |
| **Claude Code** | `claude -p --json-schema …` | `claude` → `/login` (Claude plan) |
| **OpenAI-compatible** | HTTP `/v1/chat/completions` | API key (Keychain), or none for Ollama / LM Studio |

Margins drives each vendor's own CLI, so your subscription is used exactly as the vendor intends. Margins never sees or stores those credentials. The agents run with **no tools**: no shell, no file writes, no MCP servers. They work in a scratch directory and can only return a JSON edit plan. Choose the provider and model from the toolbar; configure providers in **Settings** (⌘,).

Why it works this way: [docs/03-model-providers.md](docs/03-model-providers.md).

## Docs

1. [Motivation](docs/01-motivation.md): why not turn-based chat.
2. [Design journey](docs/02-design-journey.md): from three mockups to tracked changes ([mocks](docs/mocks/index.html)).
3. [Model providers](docs/03-model-providers.md): using Copilot, ChatGPT and Claude subscriptions.
4. [Architecture](docs/04-architecture.md): code layout, edit plans, block model, file format.
5. [Roadmap](docs/05-roadmap.md).
