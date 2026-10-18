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
        let state = AppState(untitledURL: url)
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
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(12)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            try check(condition(), "Native run completes")
        }
        func evaluate(_ body: String) async throws -> Any? { try await state.editor.call(body) }
        state.submit("DRAFT_FIXTURE")
        try await wait { !state.busy }
        try check(state.doc.intents.last?.status == .done, "First draft applies directly")
        try check(state.doc.annotationRuns.count == 1 && state.doc.annotationRuns[0].model == "fixture-model", "Native run records model and stable identity")
        let origins = try await evaluate("return window.MarginsAnnotations.getState().spans.map(s=>s.origin)") as? [String] ?? []
        try check(origins.contains("agent"), "Swift first draft reaches editor provenance engine")
        try check(state.doc.annotationRuns[0].steps.contains { $0.status == .done }, "Provider tool activity is retained in run")
        try check(state.doc.annotationRuns[0].files == ["draft.txt"], "Initial run records only its actual changed project file")
        let firstID = state.doc.annotationRuns[0].id
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
        let runCount = state.doc.annotationRuns.count
        _ = try await evaluate("const cid=document.querySelector('#doc > .chg').dataset.cid;webkit.messageHandlers.margins.postMessage({type:'refine',cid,instruction:'Simplify the proposed passage.'});return true")
        try await wait { state.doc.annotationRuns.count > runCount && !state.busy }
        try check(state.doc.annotationRuns.last?.parentRunId != nil && state.doc.annotationRuns.last?.refinement != nil, "Refinement has a distinct linked run")
        try check(state.doc.annotationRuns.last?.files == ["refine.txt"] && state.doc.annotationRuns[1].files == ["revise.txt"], "Refinement files are distinct from its contributing parent run")
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
        state.submit("SLOW_FIXTURE")
        try await Task.sleep(nanoseconds: 250_000_000)
        _ = try await evaluate("const p=document.querySelector('#doc p');p.textContent+=' Manual revision.';p.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}));return true")
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
        let secondState = AppState(untitledURL: dir.appendingPathComponent("independent-window.margins"))
        let secondWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        secondWindow.contentView = secondState.editor.webView
        await secondState.editor.ready()
        let isolatedComments = try await secondState.editor.call("return window.MarginsAnnotations.getState().comments.length") as? Int ?? -1
        let isolatedToggle = try await secondState.editor.call("return document.querySelector('#annotation-toggle').checked") as? Bool ?? true
        try check(isolatedComments == 0 && !isolatedToggle, "Separate document windows keep comments and overlay state independent")
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
