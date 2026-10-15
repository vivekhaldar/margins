# 1. Motivation: why not turn-based chat?

## The itch

I use coding and writing agents all day. Almost all of them use the same UI: a **turn-based chat transcript**. I type, it replies with a wall of text, I type again, it replies again. When the goal is to *produce an artifact* (a design doc, a plan, a memo, a spec), that paradigm gets in the way:

- **The artifact is buried in the transcript.** The current version of the document is spread across a dozen replies. "Which version had the good intro?" means scrolling.
- **Every turn rewrites everything.** Ask for a tweak to one paragraph and you get the whole document back. You have to diff it by eye to see what changed, and to check that nothing else quietly changed too.
- **There's no partial acceptance.** You can't say "yes to these two changes, no to that one". Your only lever is another prompt.
- **You can't just fix the typo yourself.** Editing the output means copying it somewhere else. At that point the agent and you are working on different copies.
- **The conversation is the state.** What really matters, the document, is a side effect of the chat history, not a first-class object.

## The idea

Flip it around: **the document is the state, and instructions are operations on it.**

- Natural language is still the input. I say what I want: "draft a design note for X", "tighten the approach section", "add an example here".
- The output is **not a reply**. It's a *change to a document* that lives in its own pane and always shows the current version.
- Each instruction **refines** the document a little. The agent proposes edits; I decide what lands.
- I'm a co-author, not a requester. I can edit the document directly at any time, and the agent works from whatever is there now.

This is how people already work with *human* collaborators on documents: suggestions mode in Google Docs, or Track Changes in Word. The interaction model is decades old and well understood. The new part is that a collaborator can propose a coherent set of edits in seconds, from a one-line instruction.

## What it should feel like

- **Low ceremony.** Typing an instruction should feel as light as typing into a search box.
- **Legible.** For any change, I should be able to see *what* changed, *why* (which instruction), and *who* made it (agent or me).
- **Granular control.** I can accept everything, one instruction's worth, a hand-picked subset, or a single hunk, or send back just one hunk with a note ("shorter").
- **Reversible.** Every step is a version with a meaningful name, so I can look back at how the document evolved and restore any point.
- **The agent never touches the document behind my back.** Agent edits are always proposals until I accept them. The one exception is the very first draft of an empty document, since there's nothing to protect yet.

## Non-goals (for now)

- A general-purpose chat client. There is no free-form Q&A; every instruction targets the document.
- Multi-user collaboration. This is a single-author tool with an AI co-author.
- Agentic tool use (browsing, running code). The agent only edits text, which keeps it fast, predictable and safe.

Continue to the [design journey](02-design-journey.md).
