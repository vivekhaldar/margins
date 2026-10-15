# 3. Model providers (ADR)

**Status:** accepted · **Context:** a native Mac app that should run on the model access the user *already pays for* (GitHub Copilot, ChatGPT, Claude), not only on metered API keys.

## Requirements

1. Use a **GitHub Copilot** subscription.
2. Use a **ChatGPT** (Plus/Pro/Team) subscription.
3. Ideally others too (Claude Pro/Max, local models, plain API keys).
4. Don't harvest, store or proxy the user's subscription credentials. Use them only the way the vendor intends.
5. Don't give the model tools. Margins only needs text in → structured edit plan out.
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
- calls `initialize` advertising **no** client capabilities (`fs.readTextFile/writeTextFile: false`, `terminal: false`);
- creates a session per request (`session/new`, about 0.5 s the first time and ~0 s after that), optionally `session/set_model`, then `session/prompt`;
- collects `agent_message_chunk` updates and answers every `session/request_permission` with *cancelled*, so even if the agent tried to use a tool, it couldn't.

`session/new` also returns the list of models your Copilot plan allows (Claude, GPT, Gemini… with premium-request multipliers), which feeds the model picker. ACP is an open protocol, so other ACP agents (Gemini CLI, etc.) are an easy extension.

### ChatGPT: Codex CLI

`codex exec --json --output-schema <schema> --ephemeral -s read-only --skip-git-repo-check -C <scratch> -c model_reasoning_effort="medium" [-m model] -`

`codex login` with a ChatGPT account means the request runs on the ChatGPT plan. `--output-schema` makes the model return JSON matching Margins' edit-plan schema. Margins reads the final `agent_message` item from the JSONL stream. The sandbox is read-only, and the scratch directory is empty.

### Claude: Claude Code CLI

`claude -p --output-format json --json-schema <schema> --system-prompt <…> --tools "" [--model]`

`claude /login` with a Claude Pro/Max account uses that plan. `--tools ""` disables all tools.

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
- ✅ No tools are granted, so there's no risk of the agent touching the filesystem.
- ⚠️ Requires the CLIs to be installed and logged in. Settings shows the detected path, and *Test connection* reports problems.
- ⚠️ CLI flags change between versions; each provider is a small adapter that is easy to update.
- ⚠️ Not sandboxed for the Mac App Store (spawning user-installed binaries). That's acceptable for a personal tool. See the [roadmap](05-roadmap.md).
