// After swift build --product Margins:
// swiftc -parse-as-library -I .build/out/Products/Debug Sources/Margins/AppState.swift \
//   Sources/Margins/EditorBridge.swift Sources/Margins/DocumentWindows.swift scripts/test-app-annotations.swift \
//   .build/out/Products/Debug/MarginsCore.o -o .build/out/Products/Debug/MarginsAnnotationIntegration
// .build/out/Products/Debug/MarginsAnnotationIntegration
// Uses a deterministic subprocess fixture, isolated preferences, and build/verification files.
import AppKit
import MarginsCore
import WebKit
import SwiftUI

// The real window coordinator is tested without constructing the full SwiftUI shell.
struct ContentView: View { var body: some View { Text("Annotation integration") } }

@main struct AnnotationIntegration {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("Native annotation integration checks passed"); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { print("FAIL: Native annotation test timed out"); exit(1) }
        app.run()
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("build/verification/native")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let git = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "--quiet", project.path])
        guard git.status == 0 else { throw NSError(domain: "Annotations", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture git init failed"]) }
        let url = dir.appendingPathComponent("session.margins")
        let suite = "MarginsAnnotationIntegration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(untitledURL: url, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = state.editor.webView
        window.makeKeyAndOrderFront(nil)
        await state.editor.ready()
        let provider = ProviderConfig(kind: .codex, name: "Annotation test fixture", binaryPath: root.appendingPathComponent("scripts/fixtures/annotation-provider.py").path, model: "fixture-model")
        state.providers = [provider]; state.activeProviderID = provider.id; state.toolPolicy = .full
        state.setProjectFolder(project)
        var passes = 0
        var checks: [String] = []
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "Annotations", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            passes += 1; checks.append(message); print("✓ \(message)")
        }
        func wait(_ message: String = "Native run completes", _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(12)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            try check(condition(), message)
        }
        func evaluate(_ body: String) async throws -> Any? { try await state.editor.call(body) }
        state.submit("DRAFT_FIXTURE")
        try await wait { !state.busy }
        try check(state.doc.intents.last?.status == .pending && state.pending.total == 1, "First draft is a pending insertion")
        try check(state.doc.annotationRuns.count == 1 && state.doc.annotationRuns[0].model == "fixture-model", "Native run records model and stable identity")
        let origins = try await evaluate("return window.MarginsAnnotations.getState().spans.map(s=>s.origin)") as? [String] ?? []
        try check(origins.contains("agent"), "Swift first draft reaches editor provenance engine")
        try check(state.doc.annotationRuns[0].steps.contains { $0.status == .done }, "Provider tool activity is retained in run")
        try check(state.doc.annotationRuns[0].files == ["draft.txt"], "Initial run records only its actual changed project file")
        let firstID = state.doc.annotationRuns[0].id
        await state.flushAndSave()
        let savedDraft = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(savedDraft.html.contains("data-kind=\"insert\"") && savedDraft.intents.last?.status == .pending,
                  "Saving preserves the first draft and its pending instruction")
        try check(String(contentsOf: state.markdownURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  "Unaccepted first draft stays out of the Markdown mirror")
        state.open(state.fileURL)
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(state.pending.total == 1 && state.doc.intents.last?.status == .pending,
                  "Reopening restores the first draft's pending review state")
        await state.editor.resolve(accept: false, all: true); await state.flushAndSave()
        let rejectedDraft = try await state.editor.blocks()
        try check(rejectedDraft.blocks.isEmpty && state.pending.total == 0 && state.doc.intents.first?.status == .reviewed,
                  "Rejecting the first draft restores an empty document and reviews the instruction")
        let rejectedSaved = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(!rejectedSaved.html.contains("Agents help authors") && rejectedSaved.annotationRuns.contains { $0.id == firstID },
                  "Saving a rejected first draft removes live text and retains its run history")
        state.submit("DRAFT_FIXTURE")
        try await wait { !state.busy }
        try check(state.doc.intents.last?.status == .pending, "A new first draft after rejection is also reviewable")
        await state.editor.resolve(accept: true, all: true); await state.flushAndSave()
        let acceptedDraft = await state.editor.html() ?? ""
        try check(state.pending.total == 0 && acceptedDraft.contains("<h1") && acceptedDraft.contains("Agents help authors") && !acceptedDraft.contains("class=\"chg"),
                  "Accepting the first draft keeps all generated blocks without pending wrappers")
        try check(String(contentsOf: state.markdownURL, encoding: .utf8).contains("Agents help authors"),
                  "Accepted first draft appears in the Markdown mirror")
        _ = try await evaluate("const p=document.querySelector('#doc p'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);window.MarginsAnnotations.addComment('Private local note');return true")
        await state.editor.flushForSave(); try await Task.sleep(nanoseconds: 80_000_000)
        state.saveNow()
        let saved = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        let commentCount = try await evaluate("return window.MarginsAnnotations.getState().comments.length") as? Int ?? 0
        try check(commentCount == 1 && saved.annotations.fields["comments"] != nil, "Local comments save through the real native message bridge")
        try check(!String(contentsOf: state.markdownURL, encoding: .utf8).contains("Private local note"), "Markdown mirror excludes local comments")
        state.submit("REVISE_FIXTURE")
        try await wait { !state.busy }
        try check(state.doc.intents.last?.status == .pending, "Ordinary agent revisions remain tracked changes")
        try check(state.doc.annotationRuns.last?.files == ["revise.txt"], "Revision run records its own changed file")
        let revisionID = state.doc.annotationRuns.last?.id
        let runCount = state.doc.annotationRuns.count
        _ = try await evaluate("const cid=document.querySelector('#doc > .chg').dataset.cid;webkit.messageHandlers.margins.postMessage({type:'refine',cid,instruction:'Simplify the proposed passage.'});return true")
        try await wait { state.doc.annotationRuns.count > runCount && !state.busy }
        try check(state.doc.annotationRuns.last?.parentRunId != nil && state.doc.annotationRuns.last?.refinement != nil, "Refinement has a distinct linked run")
        try check(state.doc.annotationRuns.last?.files == ["refine.txt"] && state.doc.annotationRuns.first(where: { $0.id == revisionID })?.files == ["revise.txt"], "Refinement files are distinct from its contributing parent run")
        await state.editor.resolve(accept: true, all: true); await state.editor.flushForSave()
        try await Task.sleep(nanoseconds: 80_000_000)
        let blocks = try await state.editor.blocks()
        let paragraph = blocks.blocks.first { $0.html.hasPrefix("<p") }!
        state.submit("Explain why this matters.", paragraphBlockID: paragraph.id)
        try await wait { !state.busy }
        try check(state.doc.annotationRuns.count > runCount + 1 && state.pending.total > 0, "Command-Enter path records attribution")
        await state.editor.resolve(accept: true, all: true); await state.editor.flushForSave()
        state.discuss(thread: UUID(), quote: "A finished explanation", focus: [paragraph.id], anchor: paragraph.id, message: "DISCUSS_FIXTURE")
        try await wait { !state.busy }
        try check(state.doc.intents.last?.thread != nil && state.doc.annotationRuns.last?.intentId == state.doc.intents.last?.id, "Discussion edit links to its originating instruction")
        await state.editor.resolve(accept: true, all: true); await state.editor.flushForSave()
        state.saveNow()
        let roundTrip = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(roundTrip.annotationRuns.contains { $0.id == firstID }, "Save retains earlier contributing runs")
        state.open(state.fileURL)
        try await Task.sleep(nanoseconds: 150_000_000)
        let restored = await state.editor.snapshot()
        try check(restored?.annotations.fields["comments"] != nil, "Reopening restores structured annotation metadata")
        // Start through the actual Command-Enter event path, then type with
        // native keyboard events while both provider subprocesses are working.
        let parallelTexts = ["SLOW_FIXTURE parallel first", "SLOW_FIXTURE parallel second"]
        _ = try await evaluate("const doc=document.querySelector('#doc');doc.insertAdjacentHTML('beforeend','<p>SLOW_FIXTURE parallel first</p><p>SLOW_FIXTURE parallel second</p><p>Concurrent writing.</p>');doc.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
        for text in parallelTexts {
            _ = try await state.editor.call("const doc=document.querySelector('#doc'),p=[...doc.children].find(p=>p.textContent===text);doc.focus();getSelection().setPosition(p,p.childNodes.length);doc.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true,bubbles:true,cancelable:true}));return true", ["text": text])
            try await wait("Command-Enter provider started for \(text)") {
                state.doc.intents.first(where: { $0.text == text })?.steps?.contains(where: { $0.id == "fixture-read" }) == true
            }
        }
        try check(state.inFlight == 2, "Two Command-Enter agents run concurrently")
        _ = try await evaluate("const doc=document.querySelector('#doc'),p=doc.lastElementChild;doc.focus();getSelection().setPosition(p,p.childNodes.length);return true")
        window.makeFirstResponder(state.editor.webView)
        func nativeType(_ text: String) async throws {
            for character in text {
                let key = String(character)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: character == " " ? 49 : 0)!
                window.sendEvent(event)
                _ = try await evaluate("return document.querySelector('#doc').lastElementChild.textContent")
            }
        }
        try await nativeType(" Before replies.")
        try await wait { !state.busy }
        try check(parallelTexts.allSatisfy { text in state.doc.intents.first(where: { $0.text == text })?.status == .pending },
                  "Both parallel Command-Enter results apply despite unrelated native typing")
        let parallelRuns = state.doc.annotationRuns.filter { parallelTexts.contains($0.instruction) }
        let attributedRuns = try await evaluate("return [...new Set(window.MarginsAnnotations.getState().spans.filter(s=>s.origin==='agent').map(s=>s.runId))]") as? [String] ?? []
        if parallelRuns.count != 2 || !parallelRuns.allSatisfy({ attributedRuns.contains($0.id.uuidString.lowercased()) }) {
            print("Parallel expected runs: \(parallelRuns.map { $0.id.uuidString.lowercased() }); attributed: \(attributedRuns)")
        }
        try check(parallelRuns.count == 2 && parallelRuns.allSatisfy { attributedRuns.contains($0.id.uuidString.lowercased()) },
                  "Parallel native results retain their separate run attribution")
        let writingCaret = try await evaluate("return document.querySelector('#doc').lastElementChild.contains(getSelection().anchorNode)") as? Bool ?? false
        try check(writingCaret, "Parallel native completions preserve the author's caret")
        try await nativeType(" After replies.")
        let writing = try await evaluate("return document.querySelector('#doc').lastElementChild.textContent") as? String
        try check(writing == "Concurrent writing. Before replies. After replies.", "Native typing continues in the same paragraph after parallel completions")
        await state.editor.resolve(accept: true, all: true); await state.editor.flushForSave()
        await state.flushAndSave()
        let parallelSaved = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(parallelSaved.html.contains("Concurrent writing. Before replies. After replies.") && parallelSaved.annotationRuns.filter { parallelTexts.contains($0.instruction) }.count == 2,
                  "Saving preserves both parallel results, run records, and concurrent typing")
        state.submit("SLOW_FIXTURE")
        try await wait("Conflicting provider started") { state.doc.intents.last(where: { $0.text == "SLOW_FIXTURE" })?.steps?.contains(where: { $0.id == "fixture-read" }) == true }
        _ = try await evaluate("const p=document.querySelector('#doc').lastElementChild;p.textContent+=' Manual revision.';p.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
        try await wait { !state.busy }
        try check(state.doc.intents.last(where: { $0.text == "SLOW_FIXTURE" })?.status == .failed, "Native bridge refuses a stale agent response")
        let html = await state.editor.html() ?? ""
        try check(html.contains("Manual revision."), "Concurrent manual edits survive stale response")
        let liveHTML = await state.editor.html() ?? ""
        let liveComments = try await evaluate("return window.MarginsAnnotations.getState().comments.length") as? Int ?? 0
        state.preview(state.doc.versions[0]); try await Task.sleep(nanoseconds: 80_000_000)
        await state.flushAndSave()
        let duringPreview = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(duringPreview.html == liveHTML, "Saving during history preview retains the live document")
        state.returnToLatest(); try await Task.sleep(nanoseconds: 80_000_000)
        let commentsAfterPreview = try await evaluate("return window.MarginsAnnotations.getState().comments.length") as? Int ?? 0
        try check(commentsAfterPreview == liveComments, "Returning to latest retains the live annotation state")
        let secondState = AppState(untitledURL: dir.appendingPathComponent("independent-window.margins"), defaults: defaults)
        let secondWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        secondWindow.contentView = secondState.editor.webView
        await secondState.editor.ready()
        let isolatedComments = try await secondState.editor.call("return window.MarginsAnnotations.getState().comments.length") as? Int ?? -1
        let isolatedToggle = try await secondState.editor.call("return document.querySelector('#annotation-toggle').checked") as? Bool ?? true
        try check(isolatedComments == 0 && !isolatedToggle, "Separate document windows keep comments and overlay state independent")
        secondState.submit("SLOW_FIXTURE first draft")
        try await wait("Blank-document provider started") { secondState.doc.intents.last?.steps?.contains(where: { $0.id == "fixture-read" }) == true }
        _ = try await secondState.editor.call("const doc=document.querySelector('#doc');doc.innerHTML='<p>My own first sentence.</p>';doc.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
        try await wait("Blank-document provider finishes") { !secondState.busy }
        let staleDraftHTML = await secondState.editor.html() ?? ""
        try check(secondState.doc.intents.first(where: { $0.text == "SLOW_FIXTURE first draft" })?.status == .failed && staleDraftHTML.contains("My own first sentence.") && !staleDraftHTML.contains("Agents help authors"),
                  "First draft refuses a stale result when the author types into the blank document")
        secondState.shutdownProviders(); await secondState.flushAndSave()
        let oldURL = state.fileURL
        let otherURL = dir.appendingPathComponent("other-document.margins")
        var other = MarginsDocument(); other.snapshot(html: "<h1>Other document</h1><p>A separate draft.</p>", slug: "fixture", author: .you)
        try other.encoded().write(to: otherURL)
        _ = try await evaluate("const p=document.querySelector('#doc p');p.textContent+=' Last keystroke before switching.';p.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
        state.open(otherURL)
        try await wait { state.fileURL == otherURL }
        let outgoing = try MarginsDocument.decode(Data(contentsOf: oldURL))
        try check(outgoing.html.contains("Last keystroke before switching."), "Switching files flushes the outgoing editor before replacing it")
        try await Task.sleep(nanoseconds: 100_000_000)
        state.submit("SLOW_FIXTURE cancel run")
        try await Task.sleep(nanoseconds: 100_000_000)
        state.stopAll(); await state.flushAndSave()
        let cancelled = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(cancelled.annotationRuns.last?.status != "working", "Stopping then immediately saving retains the final run status")
        let manager = DocumentWindows(defaults: UserDefaults(suiteName: "MarginsAnnotationIntegrationWindows")!)
        manager.register(window,state:state)
        try await Task.sleep(nanoseconds: 40_000_000)
        _ = try await evaluate("const p=document.querySelector('#doc p');p.textContent+=' Last keystroke before closing.';p.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
        manager.close(window)
        await manager.prepareToQuit()
        let closed = try MarginsDocument.decode(Data(contentsOf: state.fileURL))
        try check(closed.html.contains("Last keystroke before closing."), "Closing a window flushes its final text and matching annotations")
        state.stopAll(); state.shutdownProviders(); await state.flushAndSave()
        let result: [String: Any] = ["passed":passes,"checks":checks,"fixture":"Deterministic subprocess; no AI service call"]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:dir.deletingLastPathComponent().appendingPathComponent("annotations-native-results.json"))
        print("\(passes) native checks passed; fixture document: \(state.fileURL.path)")
    }
}
