# 2. Design journey

Margins came out of a short brainstorm-and-mock loop. The original HTML mockups are in [`docs/mocks/`](mocks/index.html); open `index.html` in a browser.

## Step 1: three alternative paradigms

All three keep natural-language input and put the output in a document pane. They differ in **how changes are presented and controlled**.

| Mock | Paradigm | Strengths | Weaknesses |
|---|---|---|---|
| **A: Tracked changes** ([mock](mocks/mock-a-tracked-changes.html)) | Instructions on the left; the agent's edits show inline as insertions and deletions you accept or reject. | Familiar (Word / Docs suggestions). Every change is legible and reversible. Granular control. | Heavy edits can look noisy. |
| **B: Margin directives** ([mock](mocks/mock-b-margin-directives.html)) | Pin instructions to specific passages, like comments; the agent resolves each in place. | Very precise scoping. Feels like reviewing a draft. | Poor for whole-document instructions. Lots of clicking. |
| **C: Brief → document** ([mock](mocks/mock-c-brief-to-document.html)) | You edit a living *brief* (goals, audience, constraints); the document regenerates from it. | Declarative. Easy to make big shifts. | Regeneration churns text you liked. Edits are less legible. |

**Decision: A, tracked changes.** It gives the strongest guarantee that the agent never changes things silently, and it degrades well: a big rewrite is just a lot of tracked changes. Mock B's precise scoping survives as *selection-scoped instructions*: select text, then type an instruction, and the agent is told to focus there.

## Step 2: "How do I select only some changes?"

Accept/reject-all is too coarse, and per-hunk is tedious when one instruction produces ten hunks. Mock A grew three levels of granularity:

- **Per instruction.** Each instruction card has *Accept these / Reject*, which applies to every change from that step. Hovering a card highlights its changes in the document.
- **Ad-hoc selection.** ⌘-click changes, or press `X` on the focused one, to build a selection. A selection bar appears with *Accept selected / Reject selected*.
- **Keyboard review.** `J`/`K` move between changes, `A`/`R` accept or reject, `X` toggles selection, `C` refines.

## Step 3: 💬 refine a single change

Accept and reject are binary. Often a change is *almost* right. Each change got a third control, **💬 refine**, which opens a small popover with quick chips ("shorter", "more formal", "add an example") and a text field. The agent rewrites **only that hunk**, given the original text, the current proposal and the surrounding context. The hunk stays pending and gets a `↻N` badge showing how many times it was refined. This is the one place a little "conversation" survives, and it's scoped to a single change, so it can't leak into the rest of the document.

## Step 4: inline editing and history

- **The document is directly editable.** You're a co-author. Your edits are captured, debounced into a "you" version, and sent to the agent as the current document next time. Pending agent changes can be edited before accepting them.
- **Versions moved into a History drawer.** The first mock had a row of `v1 v2 v3…` chips. Version numbers alone are meaningless, so each version now has:
  - a **slug** ("add summary at top", "tighten approach section"), written by the agent as part of its edit plan, or generated for your own edits and reviews ("edited §Approach", "accepted 3 changes");
  - an **author**: agent, you, or review;
  - the **instruction** that produced it.

  Clicking a version previews it read-only; *Restore* makes it current again, as a new version, so nothing is lost.

## Step 5: from mock to app

The native app keeps Mock A's interaction model almost unchanged. The editor is a ported version of the mock running in a `WKWebView`, because rich text with inline tracked-change markup is much easier in HTML/`contenteditable` than in `NSTextView`. The instruction pane, history drawer, provider picker and settings are native SwiftUI. See [architecture](04-architecture.md).

Things that changed on the way from mock to app:

- **First drafts initially landed directly.** This exception was later removed so authors can review the first draft too. It now appears as pending insertions: accept keeps the generated text, and reject returns to an empty document.
- **Agent notes.** The edit plan includes a one-line summary and any *assumptions* the agent made ("assumed a Redis-backed limiter"). These show on the instruction card and replace the chat reply you would otherwise get.
- **Quick chips** under the composer ("Tighten the prose", "Add a summary at the top"…) for common refinements.
- **Provider/model picker** in the toolbar, because different instructions deserve different models. See [model providers](03-model-providers.md).

## Step 6: a real agent behind the page

At first the backend was deliberately one-shot: document in, edit plan out, no tools. The first real use ("populate this doc with a summary of <YouTube link>") showed the problem. The model couldn't open the link, so the card just apologized. The point of Margins is that the *output* isn't chat. The *backend* can be as agentic as the task needs.

So the backend became a full agent that can reason, search, fetch, read and run commands, with three user-chosen tool levels (Off / Research / Full). The paradigm still holds: tool activity streams onto the instruction card as a compact log rather than chat turns, permission asks appear inline on that card, and the agent's final answer is still an edit plan, so whatever it found arrives as tracked changes. Details: [model providers → agent mode](03-model-providers.md#agent-mode-revision).

A second lesson came quickly: tools alone weren't enough. Asked to "make a doc from <YouTube link>", the agent searched, couldn't reach the captions, and reported that honestly. The fix was for Margins to fetch the transcript itself and hand it over. When a source is predictable and hard to reach, the app should fetch it rather than hoping the agent finds a way.

## Step 7: talking about a passage

Not every input is an instruction to change the document. Often you want to *ask* about a passage: "is this accurate?", "why this number?", "explain this". In a chat UI that means copying the text into a message, and the answer scrolls away from the thing it was about.

So Margins borrows the comment thread from document editors. Select a passage and click **Ask** (or press ⌘J), and a small thread opens beside it. The agent answers there, attached to the text. If you ask for a change instead, the edit still arrives as tracked changes in the document. The thread holds just a one-line note about it, so the document stays the output, and the thread is only for conversation *about* it. Threads collapse into 💬 markers in the margin, and each message is also recorded as a card in the instruction panel, so nothing lives only in a popover.

## Step 8: the document drives real work

The first real use exposed a gap. The author kept a planning doc for Margins itself, selected a TODO and asked "implement this". The agent answered that it only had read-only access to a scratch folder. That was true, and it was useless. The document was a plan for work on a codebase, and the agent couldn't touch the codebase.

So a document can now have a **project folder**: the repo or directory it's about. The agent runs there, and with Full agent tools it can change code, run the build and tests, and report back. The paradigm stays the same. You still direct work from the document, the agent's report lands in the thread or on the card ("Changed 2 files", each clickable), and the document is edited only when you ask ("mark this done", "describe what you built"). The doc is the plan and the record; the project is where the work happens.

Two choices matter here. Picking a folder offers to switch to Full agent, because with Codex and Claude, Research is read-only and can't prompt mid-run; a "yes" up front beats a silent refusal later. And changed files are detected by Margins itself (a `git status` snapshot plus modification times, before and after each run) rather than trusted from the model's report.
