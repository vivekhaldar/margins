# Attribution and comments

Margins records the origin of text while you write and review agent edits. Turn on **Attribution & comments** in the editor toolbar to inspect it. New document windows start with the overlay off; capture continues while it is hidden.

## Try it

1. Run the updated `build/Margins.app`. Open `build/verification/attribution-demo.margins` for a local demonstration, or generate a passage in a new document.
2. Enable **Attribution & comments**. Agent text has a subtle tint and an **AI** margin marker. Text you insert manually stays untinted. Commented text has an underline and a **C** marker. Overlapping annotations share a count.
3. Click an attributed passage or marker. Its card shows the author's instruction, provider, model, time, summary, notes, refinements, and the tool activity that was recorded. **Show in instructions** opens the corresponding instruction in the left pane. No activity is invented when a provider supplies none.
4. Select text and click **Comment**, or right-click and choose **Comment on selection**. Save a personal note without calling an agent. Edit it, add replies, resolve it, or reopen it. **Ask agent about this** explicitly starts a passage discussion.
5. Revise part of an agent passage manually. Only the new typing changes to author origin. Save and reopen: the comment and mixed attribution remain. **Browse** offers search and filters for agent contributions and open, resolved, or detached comments.
6. Remove a commented passage. Its thread stays in **Detached comments** with its quotation. Select a new passage, open the thread, and choose **Reattach to selection**.
7. Hide the overlay. The document's text and layout stay the same, and ordinary tracked-change review remains available.

The demo is explicitly labeled as a deterministic verification fixture. Its provider records and tool step demonstrate the inspector; they are not evidence of an actual AI service call.

## Persistence and editing rules

Annotations are structured metadata in the `.margins` file, stored with the exact HTML revision. Versions contain their own annotation state and run records. Historical comments and provenance are inspectable without modifying them. Restoration restores text and annotation state together.

Each agent invocation has a UUID. First drafts, ordinary instructions, Command-Enter, discussion edits, and refinements all use the same capture path. Refinements retain a link to the preceding contributing run. Pending changes retain original and proposed metadata separately: accepting preserves the proposed origin; rejecting restores the original.

New typing is author-origin; external paste is marked as pasted with unknown origin. Internal copy and paste carry separate provenance metadata, while copied HTML and plain text remain clean. Unchanged text keeps its previous origin through revisions, formatting, and paragraph splits/merges. Older documents start unattributed. Bounded alignment marks uncertain agent ranges explicitly instead of asserting exact authorship.

Coordinates use JavaScript UTF-16 code units in the text nodes of each top-level block. Lists and tables share their top-level block's space; markup, checkbox controls, and `<br>` contribute no code units. Literal text-node line breaks count. Pending original/proposed sides have separate spaces. Global UI coordinates join the active blocks with one newline. Quotation and surrounding context are recovery information; ambiguous matches detach rather than guessing.

Local comments and provenance stay out of ordinary agent prompts, copied prose, search, and Markdown output. The inspector retains the author's instruction and exposed tool activity, not a full assembled document prompt, hidden reasoning, or an execution transcript. Changing documents, closing windows, and quitting flush pending edits; a stale agent response is refused rather than overwriting a newer document revision.

## Verification

Run from the repository root:

```sh
swift run MarginsSelfTest
node scripts/test-annotation-alignment.js
swift scripts/test-editor-annotations.swift 1100 dark
swift scripts/test-editor-annotations.swift 720 light
swift scripts/test-editor-format.swift
swift scripts/test-editor-paragraph.swift
swift scripts/test-editor-typing.swift
swift scripts/test-editor-find.swift 1000
```

The WebKit suite drives the real editor and produces `build/verification/annotations-test-results.json`, a reusable demo document, and screenshots. It covers range origins, pending edits, acceptance/rejection, refinements, comment lifecycle, Unicode/list/table anchors, copying/pasting, undo/redo, stale responses, history, and the visible controls. The randomized alignment suite independently checks match validity, monotonicity, Unicode boundaries, and large-document bounds.

The typing regression checks character-by-character input into a blank document at 50%, 100%, 150%, and 300% page zoom, plus spaces, Return, deleting all content, save/reload, attribution, and selection preservation. It also sends native keyboard events and checks undo/redo. Pass an editor resource directory to run against a packaged app instead of source resources.

The visual suite requires an unoccluded macOS window. It waits for rendered animation frames and reports window visibility when rendering is suspended. Stale-response checks cover formatting and image changes as well as text edits; formatting preserves attribution while still invalidating an older agent response.

The native integration harness runs the real AppState, EditorBridge, WebKit editor, parser, provider subprocess adapter, and file saving against `scripts/fixtures/annotation-provider.py`. The fixture makes no network calls and writes only three text files inside its isolated verification repository. It checks all four agent edit flows, saved run metadata, local comments, Markdown isolation, reopening, stale-response protection, per-run changed-file attribution, and saving across preview, switching, closing, and cancellation.

```sh
swift build --product Margins
swiftc -parse-as-library -I .build/out/Products/Debug \
  Sources/Margins/AppState.swift Sources/Margins/EditorBridge.swift \
  Sources/Margins/DocumentWindows.swift \
  scripts/test-app-annotations.swift .build/out/Products/Debug/MarginsCore.o \
  -o .build/out/Products/Debug/MarginsAnnotationIntegration
.build/out/Products/Debug/MarginsAnnotationIntegration
scripts/build-app.sh
codesign --verify --deep --strict build/Margins.app
```

VoiceOver behavior and real provider-specific trace availability need manual use; automated fixtures verify the recorded-data path and accessible labels, not every backend's live output.

Metadata for undo/redo is bounded to 80 snapshots and an estimated 12 million UTF-16 units (at least two snapshots). Older undo operations preserve confidently aligned origins and mark newly restored text uncertain. Native OS drag and drop and VoiceOver interaction remain manual verification items.

## Verified local build

Build `2026101703` at `build/Margins.app` passed release compilation, signature validation, and byte-for-byte checks of all five bundled editor resources. Verification passed 148 core checks, 2,508 independent alignment cases, 52 WebKit checks in each of the two layouts, 30 native integration checks, and the existing formatting, paragraph, find, and window-session regressions. Open `build/verification/index.html` for the screenshot walkthrough and machine-readable results. `build/verification/attribution-demo.margins` is a reusable local example.
