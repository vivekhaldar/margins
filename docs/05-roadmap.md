# 5. Roadmap

Roughly in priority order.

## Editing quality
- **Word-level diffs inside replaced blocks**, so small wording tweaks don't show as a whole paragraph struck through and re-inserted.
- **Locked blocks**: mark a section "don't touch" and the agent is told to leave it alone.
- **Streaming**: show the edit plan as it arrives, especially for long first drafts.
- **Smarter scoping**: a selection inside a block becomes a sentence-level focus, not just the whole block.

## Workflow
- **Branching**: try two different directions from the same version and compare them side by side.
- **Markdown import/export**, plus copy-as-Markdown.
- **Reusable instruction snippets**: user-defined quick chips.
- **Multiple windows / documents**: a proper `DocumentGroup`.

## Providers
- **More ACP agents** (Gemini CLI, etc.): the ACP client is generic.
- **Per-instruction model choice** remembered per document.
- Surface **premium-request cost** (Copilot `copilotUsage` multipliers) in the model picker.

## Platform
- App icon, an Xcode project, notarized builds.
- Real XCTest / swift-testing suite once built with full Xcode (currently `MarginsSelfTest`).
- Optional sandboxed build that only supports HTTP providers.
