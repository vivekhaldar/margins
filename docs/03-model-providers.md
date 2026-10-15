# 3. Model providers (ADR)

**Status:** accepted · **Context:** a native Mac app that should run on the model access the user *already pays for* (GitHub Copilot, ChatGPT, Claude), not only on metered API keys.

## Requirements

1. Use a **GitHub Copilot** subscription.
2. Use a **ChatGPT** (Plus/Pro/Team) subscription.
3. Ideally others too (Claude Pro/Max, local models, plain API keys).
4. Don't harvest, store or proxy the user's subscription credentials. Use them only the way the vendor intends.
5. ~~Don't give the model tools.~~ *Revised:* let the backend be a **full agent** that can reason and call tools (web, files, shell), within a policy the user picks. Its final output is still a structured edit plan. See [Agent mode](#agent-mode-revision).
6. Be fast enough for an interactive loop.

## Options considered

| Option | Verdict |
|---|---|
| Call the vendors' HTTP APIs with API keys | Supported as a fallback, but **doesn't use subscriptions**, which was the main ask. |
| Reuse OAuth tokens that the official CLIs keep in their config dirs and call private endpoints | **Rejected.** Brittle, likely violates ToS, and means handling credentials Margins shouldn't touch. |
| Copilot SDK | No Swift binding. It wraps the same CLI anyway. |
| **Drive each vendor's official CLI as a subprocess** | **Chosen.** The CLI owns login, token refresh, entitlement checks and model availability. Margins only sends prompts and reads output. |

## Decision

A small `ModelProvider` protocol (`listModels()`, `complete(request)`) with four implementations:

### GitHub Copilot: Agent Client Protocol (ACP)

`copilot --acp --disable-builtin-mcps` speaks [ACP](https://agentclientprotocol.com) (JSON-RPC 2.0 over stdio). Margins:

- starts one long-lived process per provider, in a scratch working directory;
- calls `initialize` advertising **no** client capabilities (`fs.readTextFile/writeTextFile: false`, `terminal: false`), so the agent uses its own built-in tools rather than asking Margins to do file or terminal work;
- creates a session per request (`session/new`, about 0.5 s the first time and ~0 s after that) with `cwd` set to the document's agent workspace, optionally `session/set_model`, then `session/prompt`;
- collects `agent_message_chunk` updates, streams `tool_call` / `tool_call_update` to the UI, and answers `session/request_permission` according to the tool policy, asking the user if the policy says so.

`session/new` also returns the list of models your Copilot plan allows (Claude, GPT, Gemini… with premium-request multipliers), which feeds the model picker. ACP is an open protocol, so other ACP agents (Gemini CLI, etc.) are an easy extension.

### ChatGPT: Codex CLI

`codex exec --json --output-schema <schema> --ephemeral <policy args> --skip-git-repo-check -C <workspace> -c model_reasoning_effort="medium" [-m model] -`

`codex login` with a ChatGPT account means the request runs on the ChatGPT plan. `--output-schema` makes the model return JSON matching Margins' edit-plan schema. Margins reads the final `agent_message` item from the JSONL stream and turns `command_execution`, `web_search`, `file_change` and `mcp_tool_call` items into live tool activity. Codex never asks for permission: its OS sandbox enforces the policy.

### Claude: Claude Code CLI

`claude -p --output-format stream-json --verbose --json-schema <schema> --system-prompt <…> <policy args> [--model]`

`claude /login` with a Claude Pro/Max account uses that plan. Print mode can't prompt for permission, so the policy pre-approves a fixed tool list (`--allowedTools … --permission-mode dontAsk`). Anything else is refused.

### Anything else: OpenAI-compatible HTTP

Base URL + optional API key (stored in the macOS **Keychain**) + model. This covers OpenAI/Azure/OpenRouter API keys and **local** servers such as Ollama (`http://localhost:11434/v1`) and LM Studio with no key.

## The contract: edit plans, not documents

Every provider gets the same prompt and must return a JSON **edit plan**:

```json
{
  "slug": "add summary at top",
  "summary": "Added a short summary section after the title.",
  "notes": ["Summary restates existing content only."],
  "edits": [
    { "op": "insertAfter", "blockId": "b0", "html": "<h2>Summary</h2><p>…</p>" }
  ]
}
```

`op` is `replace | insertAfter | delete`; `blockId` refers to the `data-bid` of a top-level block (`"^"` = start of the document). Block-level edits are small, robust to model sloppiness, and map one-to-one onto tracked changes. The parser is tolerant: it strips code fences and prose around the JSON, and retries once with the parse error if the JSON is invalid.

## Agent mode (revision)

The first version deliberately gave the model no tools. In practice that was too limiting: asked to "summarize this YouTube video", the agent could only apologize. So the backend became a full agent, and the user chooses how much it may do:

| Policy | Copilot (ACP) | Codex | Claude |
|---|---|---|---|
| **Off** | every permission request rejected | `-s read-only`, `web_search="disabled"` | `--tools ""` |
| **Research** (default) | fetch / search / read auto-allowed; execute / edit / delete → **inline Allow/Deny prompt** | `-s read-only`, `web_search="live"` | `WebFetch, WebSearch, Read, Grep, Glob` |
| **Full agent** | everything allowed | `-s workspace-write`, network on, live search | + `Bash, Write, Edit` |

Design points:

- **The output contract doesn't change.** However much the agent explores, its *final* message must be the edit-plan JSON. Narration before tool calls is shown as "thinking", not parsed. If the final JSON is malformed, the retry asks for a **reformat only** (tools off), so the research isn't repeated.
- **One workspace per document** (`~/Library/Application Support/Margins/Workspaces/<doc-id>/`). Downloads and scratch scripts persist between instructions on the same document and never land next to your files.
- **Visible and stoppable.** Tool calls stream onto the instruction card. Stop (⌘.) cancels the run (ACP `session/cancel`, or the subprocess is terminated).
- **Security.** Codex has the strongest guarantee (OS sandbox). Copilot relies on its permission protocol, which Margins answers per policy. Claude relies on its allow-list. In *Full agent*, commands can still reach outside the workspace on Copilot and Claude, so use it deliberately.

Measured on "populate doc with summary of <a YouTube talk>": Copilot (Research) fetched the page, asked to run `curl`/`pip`, found no transcript and wrote the summary from the description in ~15 s. Codex (Full) ran searches and commands, found a transcript of the same talk and wrote a detailed summary in ~65 s.

## Measured (M-series Mac, this prototype)

| Provider / model | Typical edit-plan latency |
|---|---|
| Copilot / claude-haiku-5.5 | ~4 s |
| Copilot / claude-sonnet-5.5 (Copilot default) | ~25–30 s for a full first draft |
| Codex / gpt-6.1-sol (medium effort) | ~9 s |

A fast model is plenty for most refinements; switch models per instruction from the toolbar.

## Consequences

- ✅ Uses the subscriptions people already have. Margins never handles their tokens.
- ✅ Each vendor's own CLI keeps entitlement, quota and model lists correct.
- ✅ Tools are opt-in by level, and the default (*Research*) asks before anything that changes state.
- ⚠️ Agent runs are slower and costlier than one-shot edits. Switch to *Off* for quick rewrites.
- ⚠️ Requires the CLIs to be installed and logged in. Settings shows the detected path, and *Test connection* reports problems.
- ⚠️ CLI flags change between versions; each provider is a small adapter that is easy to update.
- ⚠️ Not sandboxed for the Mac App Store (spawning user-installed binaries). That's acceptable for a personal tool. See the [roadmap](05-roadmap.md).
