import Foundation
@testable import MarginsCore

// Minimal test runner (Command Line Tools lack XCTest and the swift-testing macro plugin).
// Run: swift run MarginsSelfTest

var failures = 0
var passes = 0

func check(_ cond: @autoclosure () throws -> Bool, _ msg: String, line: Int = #line) {
    do {
        if try cond() { passes += 1 } else { failures += 1; print("✗ line \(line): \(msg)") }
    } catch {
        failures += 1; print("✗ line \(line): \(msg) threw \(error)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { failures += 1; print("✗ \(name) threw \(error)") }
}

runSemanticZoomTests()
runGenerationSchemaTests()

test("agent target persistence and fallback") {
    let first = ProviderConfig(kind: .copilot)
    var preferred = ProviderConfig(kind: .codex)
    for target in [AgentTarget.local(preferred.id), .cloud(.amp), .cloud(.copilot)] {
        let data = try JSONEncoder().encode(target)
        check(try JSONDecoder().decode(AgentTarget.self, from: data) == target, "agent target round-trips")
    }
    check(AgentTarget.localFallback(preferred: preferred.id, providers: [first, preferred]) == preferred.id,
          "keep the remembered enabled provider")
    preferred.enabled = false
    check(AgentTarget.localFallback(preferred: preferred.id, providers: [preferred, first]) == first.id,
          "skip a disabled provider even if it is first")
    check(AgentTarget.localFallback(preferred: preferred.id, providers: [first]) == first.id,
          "fall back when the remembered provider is removed")
    check(AgentTarget.localFallback(preferred: preferred.id, providers: [preferred]) == nil,
          "no disabled provider is returned as usable")
}

test("toggle agent targets and disable active cloud backend") {
    let providerID = UUID()
    let local = AgentTarget.local(providerID)
    let cloud = AgentTarget.cloud(.amp)
    let all = Set(CloudBackend.allCases)
    check(local.toggled(lastLocal: providerID, lastCloud: .amp, enabledCloud: all) == cloud,
          "switch to the remembered cloud backend")
    check(cloud.toggled(lastLocal: providerID, lastCloud: .amp, enabledCloud: all) == local,
          "switch back to the remembered local provider")
    check(local.toggled(lastLocal: providerID, lastCloud: .amp, enabledCloud: [.copilot]) == .cloud(.copilot),
          "fall back to an enabled backend if the last cloud choice is disabled")
    check(local.toggled(lastLocal: providerID, lastCloud: .amp, enabledCloud: []) == local,
          "stay local when no cloud backend is enabled")
    check(cloud.resolvingDisabledCloud(lastLocal: providerID, enabledCloud: [.copilot]) == local,
          "disabling the active cloud backend falls back to local, not another cloud agent")
    check(cloud.resolvingDisabledCloud(lastLocal: providerID, enabledCloud: [.amp]) == cloud,
          "disabling a different backend leaves the active cloud agent alone")
}

test("open window session round trip and restoration") {
    let first = URL(fileURLWithPath: "/documents/first.margins")
    let second = URL(fileURLWithPath: "/documents/second.margins")
    let missing = URL(fileURLWithPath: "/documents/missing.margins")
    let session = WindowSession(windows: [
        .init(url: first, frame: "{{10, 20}, {1280, 820}}"),
        .init(url: second, frame: "{{50, 60}, {1000, 700}}", miniaturized: true)
    ], activeURL: first)
    let decoded = try JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(session))
    check(decoded == session, "all document paths, geometry, minimized state and focus survive relaunch")
    check(decoded.restorable { _ in true } == session, "restore every valid window in order")
    let filtered = WindowSession(windows: session.windows + [
        .init(url: missing, frame: ""),
        .init(url: first.deletingLastPathComponent().appendingPathComponent("./first.margins"), frame: "duplicate"),
        .init(url: URL(string: "https://example.com/document")!, frame: "")
    ], activeURL: missing).restorable { $0 != missing }
    check(filtered.windows == session.windows, "skip missing documents, non-files and duplicate paths")
    check(filtered.activeURL == nil, "unavailable active document does not block restoration")
    let closed = WindowSession(windows: [session.windows[1]], activeURL: second)
    check(closed.restorable { _ in true }.windows.map(\.url) == [second], "closed document stays closed")
    check(WindowSession().restorable { _ in true }.windows.isEmpty, "explicit empty session remains empty")
    check((try? JSONDecoder().decode(WindowSession.self, from: Data("invalid".utf8))) == nil,
          "invalid session data can fall back safely")
}

test("parse bare JSON") {
    let p = try EditPlanParser.parse(#"{"slug":"tighten intro","summary":"s","notes":[],"edits":[{"op":"replace","blockId":"b1","html":"<p>x</p>"}]}"#)
    check(p.slug == "tighten intro", "slug")
    check(p.edits == [EditOp(op: .replace, blockId: "b1", html: "<p>x</p>")], "edits")
}

test("parse fenced JSON with prose") {
    let text = "Sure! Here you go:\n```json\n{\"edits\":[{\"op\":\"delete\",\"blockId\":\"b2\"}]}\n```\nLet me know."
    let p = try EditPlanParser.parse(text)
    check(p.edits.first?.op == .delete, "delete op")
    check(p.edits.first?.html == "", "missing html defaults to empty")
    check(p.notes.isEmpty && p.slug.isEmpty, "optional fields default")
}

test("parse JSON embedded in prose with braces in strings") {
    let text = #"Plan: {"slug":"a","summary":"uses {braces}","notes":["q?"],"edits":[{"op":"insertAfter","blockId":"^","html":"<h1>T</h1>"}]} done"#
    let p = try EditPlanParser.parse(text)
    check(p.summary == "uses {braces}", "string braces")
    check(p.edits.first?.blockId == "^", "start anchor")
}

test("parse rejects non-JSON") {
    check((try? EditPlanParser.parse("I can't help with that")) == nil, "should throw")
}

test("schema is valid JSON and strict") {
    let o = EditPlanSchema.object
    check(o["additionalProperties"] as? Bool == false, "strict")
    check((o["required"] as? [String])?.count == 5, "required fields")
}

test("prompt builder") {
    let s = PromptBuilder.editPrompt(blocks: [Block(id: "b1", html: "<p>a</p>"), Block(id: "b2", html: "<p>b</p>", pending: true)],
                                     instruction: "shorter", focus: ["b2"])
    check(s.contains("[b1] <p>a</p>"), "block 1")
    check(s.contains("[b2] (pending suggestion)"), "pending marker")
    check(s.contains("selected blocks [b2]"), "focus")
    check(PromptBuilder.editPrompt(blocks: [], instruction: "x").contains("(empty)"), "empty doc")
    let r = PromptBuilder.refinePrompt(blocks: [], blockId: "b9", original: "", proposed: "<p>n</p>", originalInstruction: "add", refinement: "shorter")
    check(r.contains("blockId \"b9\"") && r.contains("this was an insertion"), "refine prompt")
}

test("paragraph prompt writes an answer at its original location") {
    let blocks = [Block(id: "b1", html: "<h1>Context</h1>"),
                  Block(id: "b2", html: "<p>Why does this matter?</p>")]
    let prompt = PromptBuilder.paragraphPrompt(blocks: blocks, blockId: "b2", instruction: "Why does this matter?")
    check(prompt.contains("[b1] <h1>Context</h1>"), "paragraph answer receives surrounding context")
    check(prompt.contains("blockId \"b2\""), "replacement targets the originating block")
    check(prompt.contains("reply alone does not fulfill"), "questions still require document edits")
    check(prompt.contains("preserve the rest of that block"), "nested prompts preserve their container")
    check(prompt.contains("ROUGH PROMPT\nWhy does this matter?"), "rough instruction retained")
    let ordinary = PromptBuilder.editPrompt(blocks: blocks, instruction: "Why does this matter?")
    check(!ordinary.contains("ROUGH PROMPT"), "ordinary submissions keep their behavior")
}

test("document round trip and title") {
    var d = MarginsDocument()
    check(d.title == "Untitled", "untitled")
    d.snapshot(html: "<h1 data-bid=\"b1\">Rate <em>Limits</em></h1><p>x</p>", slug: "first draft", author: .agent)
    d.intents.append(Intent(step: 1, text: "write it", status: .pending))
    check(d.title == "Rate Limits", "title from h1")
    check(d.versions.count == 1 && d.versions[0].number == 1, "version numbering")
    d.snapshot(html: d.html + "<p>y</p>", slug: "edited", author: .you)
    check(d.versions.last?.number == 2, "v2")
    let back = try MarginsDocument.decode(try d.encoded())
    check(back.html == d.html && back.versions.map(\.slug) == d.versions.map(\.slug) && back.intents.map(\.id) == d.intents.map(\.id), "round trip")
}

test("annotation storage, history, and legacy documents") {
    var document = MarginsDocument(html: "<p data-bid=\"b1\">A 🧭 mixed passage</p>")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let intent = Intent(step: 1, text: "Explain the passage", createdAt: date, provider: "Test provider")
    document.intents = [intent]
    let run = AnnotationRun(intentId: intent.id, step: 1, provider: "Test provider", model: "test-model", createdAt: date,
                            instruction: intent.text, summary: "Added an explanation", status: "done")
    document.annotationRuns = [run]
    let annotations = DocumentAnnotations(fields: [
        "schema": .number(1), "revision": .number(7),
        "spans": .array([.object(["blockId": .string("b1"), "start": .number(2), "end": .number(4),
                                  "origin": .string("agent"), "runId": .string(run.id.uuidString.lowercased())])]),
        "comments": .array([.object(["id": .string("local-comment"), "body": .string("Private editorial note"),
                                     "resolved": .bool(false), "detached": .bool(false), "extra": .null])]),
        "futureField": .object(["retainUnknown": .bool(true)])
    ])
    document.annotations = annotations
    document.snapshot(html: document.html, slug: "explained", author: .agent, at: date)
    document.annotations.fields["revision"] = .number(8)
    document.snapshot(html: document.html + "<p>Later revision</p>", slug: "revised", author: .you, at: date)
    let decoded = try MarginsDocument.decode(try document.encoded())
    check(decoded == document, "annotation document and both version snapshots round trip without losing unknown fields")
    check(decoded.annotations.revision == 8, "live annotation revision persists")
    check(decoded.versions[0].annotations == annotations, "historical annotation state stays immutable")
    check(decoded.versions[0].annotationRuns == [run], "version keeps provider, model and stable run identity")
    var legacy = try JSONSerialization.jsonObject(with: document.encoded()) as! [String: Any]
    legacy["format"] = 1
    legacy.removeValue(forKey: "annotations"); legacy.removeValue(forKey: "annotationRuns")
    legacy["versions"] = (legacy["versions"] as! [[String: Any]]).map { v in
        var old = v; old.removeValue(forKey: "annotations"); old.removeValue(forKey: "annotationRuns"); return old
    }
    let old = try MarginsDocument.decode(try JSONSerialization.data(withJSONObject: legacy))
    check(old.annotations.fields.isEmpty && old.annotationRuns.isEmpty, "old files open without invented provenance")
    check(old.versions.allSatisfy { $0.annotations.fields.isEmpty && $0.annotationRuns.isEmpty }, "legacy versions open with empty annotation state")
    let blocks = [Block(id: "b1", html: "<p>A mixed passage</p>")]
    let prompt = PromptBuilder.editPrompt(blocks: blocks, instruction: "Tighten")
    check(!prompt.contains("Private editorial note") && !prompt.contains(run.id.uuidString), "ordinary prompts contain prose without local annotation metadata")
}

test("reasoning effort settings and Codex overrides") {
    let config = ProviderConfig(kind: .codex, model: "gpt-6.1-sol", reasoningEffort: .high)
    let encoded = try JSONEncoder().encode(config)
    check(try JSONDecoder().decode(ProviderConfig.self, from: encoded) == config, "effort survives saved provider settings")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    legacy.removeValue(forKey: "reasoningEffort")
    let old = try JSONDecoder().decode(ProviderConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
    check(old.reasoningEffort == nil && old.model == config.model && old.id == config.id,
          "old provider settings retain model and identity with default effort")
    check(CodexExecProvider.effortArguments(nil).isEmpty, "default does not override Codex configuration")
    for effort in ReasoningEffort.allCases {
        let request = GenerationRequest(system: "s", prompt: "p", reasoningEffort: effort)
        check(CodexExecProvider.effortArguments(request.reasoningEffort) == ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""],
              "selected \(effort.rawValue) is passed as a TOML CLI override")
    }
}

test("codex JSONL extraction") {
    let jsonl = """
    {"type":"thread.started","thread_id":"x"}
    {"type":"item.completed","item":{"id":"0","type":"reasoning","text":"thinking"}}
    {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"{\\"edits\\":[]}"}}
    {"type":"turn.completed","usage":{}}
    """
    check(CodexExecProvider.lastAgentMessage(jsonl: jsonl) == #"{"edits":[]}"#, "agent message")
    check(CodexExecProvider.firstError(jsonl: #"{"type":"error","message":"boom"}"#) == "boom", "error")
}

test("claude output extraction") {
    let structured = #"{"type":"result","is_error":false,"result":"","structured_output":{"edits":[]}}"#
    check(try ClaudeCodeProvider.extract(stdout: structured, status: 0, stderr: "") == #"{"edits":[]}"#, "structured_output")
    let plain = #"{"type":"result","is_error":false,"result":"{\"edits\":[]}"}"#
    check(try ClaudeCodeProvider.extract(stdout: plain, status: 0, stderr: "") == #"{"edits":[]}"#, "result string")
    let err = #"{"type":"result","is_error":true,"result":"Failed to authenticate"}"#
    check((try? ClaudeCodeProvider.extract(stdout: err, status: 0, stderr: "")) == nil, "auth error throws")
}

test("markdown export") {
    let md = MarkdownExporter.markdown(fromHTML: """
    <h1 data-bid="b1" class="">Design Note: A &amp; B</h1><p data-bid="b2">Use <strong>Redis</strong>, <em>not</em> <code>memcached</code>; see <a href="https://x.dev">docs</a>. snake_case 2*3</p>\
    <ul data-bid="b3"><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol>\
    <div class="chg" data-cid="c1" data-kind="replace"><del contenteditable="false"><p>Old accepted text.</p></del><ins><p>Proposed text.</p></ins><span class="tools" contenteditable="false"><button>✓</button></span></div>\
    <div class="chg" data-kind="insert"><del contenteditable="false"></del><ins><p>Pending insertion.</p></ins></div>\
    <pre><code>let x = 1</code></pre><blockquote><p>Quoted</p></blockquote><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table><p>line<br>break</p>
    """)
    check(md.hasPrefix("# Design Note: A & B\n\n"), "heading + entity")
    check(md.contains("Use **Redis**, *not* `memcached`; see [docs](https://x.dev). snake_case 2\\*3"), "inline formatting")
    check(md.contains("- one\n- two\n  - nested"), "nested list")
    check(md.contains("1. first\n2. second"), "ordered list")
    check(md.contains("Old accepted text.") && !md.contains("Proposed text.") && !md.contains("Pending insertion."), "pending changes export accepted text")
    check(!md.contains("✓"), "change chrome stripped")
    check(md.contains("```\nlet x = 1\n```") && md.contains("> Quoted"), "code block + quote")
    check(md.contains("| A | B |\n| --- | --- |\n| 1 | 2 |"), "table")
    check(md.contains("line  \nbreak"), "line break")
}

test("checklist markdown export") {
    let md = MarkdownExporter.markdown(fromHTML: """
    <ul data-task><li><input type="checkbox">Todo</li><li><input type="checkbox" checked>Done<ul><li>Detail</li></ul></li></ul>
    """)
    check(md.contains("- [ ] Todo"), "unchecked task")
    check(md.contains("- [x] Done\n      - Detail"), "checked task with nested list")
}

test("assets") {
    var doc = MarginsDocument()
    let svg = #"<svg viewBox="0 0 10 10" width="100"><title>Flow</title><rect width="5" height="5"/></svg>"#
    let html = doc.internalizeImages("<figure>\(svg)<figcaption>Cap</figcaption></figure><p><img src=\"data:image/png;base64,iVBORw0KGgo=\" alt=\"x\"></p>")
    check(!html.contains("<svg") && !html.contains("data:"), "inline svg + data uri moved out")
    check(doc.assets.count == 2, "two assets stored")
    check(html.contains("alt=\"Flow\"") && html.contains(".svg\""), "svg alt from <title>, .svg url")
    let ids = MarginsDocument.assetIDs(in: html)
    check(ids.count == 2 && ids.allSatisfy { doc.assets[$0] != nil }, "ids resolve")
    let svgID = ids.first { doc.assets[$0]?.mime == "image/svg+xml" }!
    check(String(data: doc.assets[svgID]!.data, encoding: .utf8)!.contains("xmlns=\"http://www.w3.org/2000/svg\""), "xmlns added")
    let again = doc.internalizeImages(svg)
    check(doc.assets.count == 2 && MarginsDocument.assetIDs(in: again) == [svgID], "content-addressed dedupe")
    let expanded = doc.expandSVGForPrompt(html)
    check(expanded.contains("<rect") && !expanded.contains(".svg\"") && expanded.contains(".png\""), "svg expanded for prompt, png kept")
    check(doc.inliningAssets(html).contains("data:image/svg+xml;base64,"), "export inlines assets")
    doc.snapshot(html: html, slug: "x", author: .agent)
    doc.snapshot(html: "<p>no images</p>", slug: "y", author: .you)
    doc.addAsset(Data("orphan".utf8), mime: "image/png")
    doc.pruneAssets()
    check(doc.assets.count == 2, "prune keeps history-referenced, drops orphans")
    let round = try MarginsDocument.decode(try doc.encoded())
    check(round.assets == doc.assets, "assets round-trip")
    let legacy = try MarginsDocument.decode(Data(#"{"format":1,"html":"","intents":[],"versions":[],"nextStep":1}"#.utf8))
    check(legacy.assets.isEmpty, "old files without assets decode")
    let md = MarkdownExporter.markdown(fromHTML: html) { src in
        MarginsDocument.assetID(fromSrc: src).map { "T.assets/\($0).svg" } ?? src
    }
    check(md.contains("![Flow](T.assets/") && md.contains("*Cap*"), "markdown image + caption")
}

test("binary locator") {
    check(BinaryLocator.locate("sh") != nil, "finds sh")
    check(BinaryLocator.locate("definitely-not-a-binary-xyz") == nil, "missing")
    check(BinaryLocator.locate("x", override: "/bin/sh")?.path == "/bin/sh", "override")

    // GUI launch inherits only minimal system PATH: login shell PATH and ~/bin come before /usr/bin.
    let guiEnv = BinaryLocator.childEnvironment(
        base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/test", "CUSTOM": "1"],
        loginShellDirectories: ["/Users/test/bin", "/Users/test/.nvm/versions/node/v22/bin", "/usr/bin", "/bin"],
        home: "/Users/test",
        extraDirectories: ["/Users/test/custom/bin"]
    )
    let guiDirs = BinaryLocator.splitPath(guiEnv["PATH"])
    check(guiEnv["CUSTOM"] == "1", "preserves inherited env vars")
    check(guiDirs.first == "/Users/test/bin", "login shell PATH precedes minimal GUI PATH")
    check(guiDirs.contains("/Users/test/.nvm/versions/node/v22/bin"), "includes login shell node dir")
    check(guiDirs.contains("/Users/test/custom/bin"), "includes executable parent dir")
    check(guiDirs.firstIndex(of: "/Users/test/bin")! < guiDirs.firstIndex(of: "/usr/bin")!, "~/bin precedes /usr/bin")
    check(Set(guiDirs).count == guiDirs.count, "deduplicates PATH entries")

    // Even if login shell PATH is empty, ~/bin and common dirs still precede minimal GUI /usr/bin.
    let fallbackDirs = BinaryLocator.mergedSearchDirectories(
        inheritedPath: "/usr/bin:/bin:/usr/sbin:/sbin",
        loginShellDirectories: [],
        home: "/Users/test"
    )
    check(fallbackDirs.first == "/Users/test/bin", "fallback includes ~/bin first on minimal GUI PATH")
    check(fallbackDirs.contains("/Users/test/.local/bin") && fallbackDirs.contains("/opt/homebrew/bin"), "includes standard fallbacks")
    check(fallbackDirs.firstIndex(of: "/Users/test/bin")! < fallbackDirs.firstIndex(of: "/usr/bin")!, "fallback ~/bin precedes /usr/bin")

    // Rich caller PATH keeps caller precedence while appending login shell and fallback dirs.
    let cliDirs = BinaryLocator.mergedSearchDirectories(
        inheritedPath: "/override/bin:/usr/bin:/bin",
        loginShellDirectories: ["/Users/test/bin", "/usr/bin"],
        home: "/Users/test"
    )
    check(cliDirs.first == "/override/bin", "custom inherited PATH keeps precedence")
    check(cliDirs.contains("/Users/test/bin"), "merges login shell dirs into custom PATH")
    check(Set(cliDirs).count == cliDirs.count, "deduplicates merged CLI PATH")

    // Marker extraction isolates PATH from noisy shell profiles and preserves spaces.
    let noisy = "Welcome to zsh!\n__START__/Users/test/My Apps/bin:/Users/test/bin:/usr/bin\n__END__\nbye\n"
    check(BinaryLocator.extractMarkedOutput(noisy, startMarker: "__START__", endMarker: "__END__") == "/Users/test/My Apps/bin:/Users/test/bin:/usr/bin",
          "isolates PATH from profile noise")
    check(BinaryLocator.extractMarkedOutput("no markers here", startMarker: "__START__", endMarker: "__END__") == nil,
          "missing markers return nil")

    // Shell selection honors executable supported $SHELL and falls back to /bin/zsh.
    check(BinaryLocator.loginShellURL(environment: ["SHELL": "/opt/homebrew/bin/bash"], isExecutable: { _ in true }).path == "/opt/homebrew/bin/bash",
          "uses supported executable $SHELL")
    check(BinaryLocator.loginShellURL(environment: ["SHELL": "/opt/homebrew/bin/fish"], isExecutable: { _ in true }).path == "/opt/homebrew/bin/fish",
          "supports fish $SHELL")
    check(BinaryLocator.loginShellURL(environment: ["SHELL": "/sbin/nologin"], isExecutable: { _ in true }).path == "/bin/zsh",
          "falls back to /bin/zsh for unsupported shell")
    check(BinaryLocator.loginShellURL(environment: ["SHELL": "/no/such/zsh"], isExecutable: { _ in false }).path == "/bin/zsh",
          "falls back to /bin/zsh for non-executable shell")
    check(BinaryLocator.loginShellURL(environment: [:], isExecutable: { _ in true }).path == "/bin/zsh",
          "falls back to /bin/zsh when $SHELL is unset")
    check(BinaryLocator.loginShellPathCommand(for: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), startMarker: "S", endMarker: "E").contains("/usr/bin/printenv PATH"),
          "fish uses printenv PATH for colon-separated output")

    // Shell execution captures marked output amid noise and times out cleanly on hangs.
    let noisyRun = BinaryLocator.runShellCommand(
        shell: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo banner; printf '%s%s%s' '__S__' '/custom/bin:/usr/bin' '__E__'; echo footer"],
        timeout: 2.0
    )
    check(noisyRun.flatMap { BinaryLocator.extractMarkedOutput($0, startMarker: "__S__", endMarker: "__E__") } == "/custom/bin:/usr/bin",
          "shell command extracts marked PATH amid stdout noise")
    let timedOut = BinaryLocator.runShellCommand(shell: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 5"], timeout: 0.2)
    check(timedOut == nil, "shell command times out cleanly")

    // Live childEnvironment always includes ~/bin and standard system dirs.
    let liveHome = FileManager.default.homeDirectoryForCurrentUser.path
    let liveDirs = BinaryLocator.splitPath(BinaryLocator.childEnvironment["PATH"])
    check(liveDirs.contains("\(liveHome)/bin") && liveDirs.contains("/usr/bin") && liveDirs.contains("/bin"),
          "live childEnvironment includes ~/bin and system dirs")
}

test("agent policy auto-decisions") {
    let ws = URL(fileURLWithPath: "/tmp")
    let research = AgentContext(policy: .research, workspace: ws)
    check(research.autoDecision(for: .fetch) == .allowOnce, "research allows fetch")
    check(research.autoDecision(for: .read) == .allowOnce, "research allows read")
    check(research.autoDecision(for: .execute) == nil, "research asks for execute")
    check(research.autoDecision(for: .edit) == nil, "research asks for edit")
    check(AgentContext(policy: .full, workspace: ws).autoDecision(for: .execute) == .allowAlways, "full allows execute")
    check(AgentContext(policy: .off, workspace: ws).autoDecision(for: .fetch) == .deny, "off denies")
    check(GenerationRequest(system: "", prompt: "", agent: AgentContext(policy: .off, workspace: ws)).tools == nil, "off → no tools")
    check(GenerationRequest(system: "", prompt: "", agent: research).tools != nil, "research → tools")
}

test("tool-aware system prompt") {
    let ws = URL(fileURLWithPath: "/tmp/ws-xyz")
    check(PromptBuilder.system.contains("never use tools"), "one-shot forbids tools")
    let s = PromptBuilder.system(tools: AgentContext(policy: .full, workspace: ws))
    check(!s.contains("never use tools") && s.contains("/tmp/ws-xyz") && s.contains("run shell commands"), "full prompt")
    check(s.contains("FINAL message must be exactly one JSON object") && s.contains(EditPlanSchema.json), "schema kept")
    check(PromptBuilder.system(tools: AgentContext(policy: .research, workspace: ws)).contains("need the author's approval"), "research prompt")
}

test("ACP permission outcome mapping") {
    let opts: [[String: Any]] = [["optionId": "a1", "kind": "allow_once"], ["optionId": "a2", "kind": "allow_always"],
                                 ["optionId": "r1", "kind": "reject_once"]]
    check(ACPProvider.outcome(.allowOnce, options: opts)["optionId"] as? String == "a1", "allow once")
    check(ACPProvider.outcome(.allowAlways, options: opts)["optionId"] as? String == "a2", "allow always")
    check(ACPProvider.outcome(.deny, options: opts)["optionId"] as? String == "r1", "deny")
    check(ACPProvider.outcome(.deny, options: [])["outcome"] as? String == "cancelled", "no options → cancelled")
    let step = ACPProvider.step(from: ["toolCallId": "t1", "kind": "fetch", "title": "Fetching x", "status": "pending",
                                       "rawInput": ["url": "https://x.dev"]], denied: TextCollector())
    check(step == AgentStep(id: "t1", kind: .fetch, title: "Fetching x", detail: "https://x.dev", status: .running), "acp step")
}

test("codex exec events") {
    let started = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi > hi.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#
    guard case .step(let s)? = CodexExecProvider.events(started).first else { check(false, "no step"); return }
    check(s.kind == .execute && s.detail == "echo hi > hi.txt" && s.status == .running, "command started")
    let failed = #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"ls","exit_code":2,"status":"failed"}}"#
    if case .step(let f)? = CodexExecProvider.events(failed).first { check(f.status == .failed, "command failed") } else { check(false, "no fail step") }
    let search = #"{"type":"item.completed","item":{"id":"ws_1","type":"web_search","query":"andrew ng"}}"#
    if case .step(let w)? = CodexExecProvider.events(search).first { check(w.kind == .search && w.detail == "andrew ng" && w.status == .done, "web search") } else { check(false, "no search") }
    let final = #"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"{\"edits\":[]}"}}"#
    check(CodexExecProvider.events(final).isEmpty, "final answer is not a thought")
    check(CodexExecProvider.policyArguments(.full).contains("workspace-write"), "full sandbox")
    check(CodexExecProvider.policyArguments(.research).contains("read-only"), "research sandbox")
}

test("codex models cache loading and fallback") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-codex-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let cacheURL = dir.appendingPathComponent("models_cache.json")
    let json = #"""
    {
      "models": [
        {"slug": "gpt-6.2-astra", "display_name": "GPT-6.2-Astra", "visibility": "list", "priority": 2},
        {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide", "priority": 0},
        {"slug": "gpt-6.2-sol", "display_name": "GPT-6.2-Sol", "visibility": "list", "priority": 1},
        {"slug": "gpt-no-name", "display_name": "  ", "visibility": "list", "priority": 5},
        {"slug": "gpt-no-priority", "visibility": "list"},
        {"slug": "gpt-6.2-sol", "display_name": "Duplicate", "visibility": "list", "priority": 9},
        {"slug": "gpt-unlisted", "display_name": "Unlisted", "priority": 0}
      ]
    }
    """#
    try Data(json.utf8).write(to: cacheURL)
    let loaded = CodexExecProvider.availableModels(cacheURL: cacheURL)
    check(loaded == [
        ModelInfo(id: "", name: "Default (from ~/.codex/config.toml)"),
        ModelInfo(id: "gpt-6.2-sol", name: "GPT-6.2-Sol"),
        ModelInfo(id: "gpt-6.2-astra", name: "GPT-6.2-Astra"),
        ModelInfo(id: "gpt-no-name", name: "gpt-no-name"),
        ModelInfo(id: "gpt-no-priority", name: "gpt-no-priority")
    ], "filters visibility==list, sorts by priority, maps slug/display_name, prepends default")

    let expectedFallback = [
        ModelInfo(id: "", name: "Default (from ~/.codex/config.toml)"),
        ModelInfo(id: "gpt-6.1-sol", name: "gpt-6.1-sol"),
        ModelInfo(id: "gpt-6-luna", name: "gpt-6-luna")
    ]
    let missingURL = dir.appendingPathComponent("missing.json")
    check(CodexExecProvider.availableModels(cacheURL: missingURL) == expectedFallback,
          "falls back to hardcoded list when cache file is absent")

    try Data("not valid json".utf8).write(to: cacheURL)
    check(CodexExecProvider.availableModels(cacheURL: cacheURL) == expectedFallback,
          "falls back to hardcoded list when cache file is unreadable/corrupt")

    try Data(#"{"models":[{"slug":"hidden","visibility":"hide","priority":1}]}"#.utf8).write(to: cacheURL)
    check(CodexExecProvider.availableModels(cacheURL: cacheURL) == expectedFallback,
          "falls back to hardcoded list when no models have visibility==list")
}

test("claude stream-json events") {
    let names = ClaudeCodeProvider.ToolNames()
    let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://a.b","prompt":"x"}}]}}"#
    guard case .step(let s)? = ClaudeCodeProvider.events(use, names: names).first else { check(false, "no step"); return }
    check(s.kind == .fetch && s.detail == "https://a.b" && s.status == .running, "tool_use")
    let res = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"nope"}]}}"#
    if case .step(let r)? = ClaudeCodeProvider.events(res, names: names).first { check(r.status == .failed && r.kind == .fetch, "tool_result") } else { check(false, "no result") }
    let so = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"StructuredOutput","input":{}}]}}"#
    check(ClaudeCodeProvider.events(so, names: names).isEmpty, "StructuredOutput hidden")
    check(ClaudeCodeProvider.policyArguments(.research).contains("WebFetch,WebSearch,Read,Grep,Glob"), "research tools")
    check(!ClaudeCodeProvider.policyArguments(.research).joined().contains("Bash"), "research has no Bash")
}

test("document id round-trips; old docs get one") {
    var d = MarginsDocument(html: "<h1>x</h1>")
    d.intents = [Intent(step: 1, text: "t")]
    d.intents[0].steps = [AgentStep(id: "a", kind: .fetch, title: "Fetch", status: .done)]
    let back = try MarginsDocument.decode(try d.encoded())
    check(back.id == d.id, "id persisted")
    check(back.intents[0].steps?.first?.kind == .fetch, "steps persisted")
    let legacy = try MarginsDocument.decode(Data(#"{"html":"","intents":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"instruction","step":1,"text":"t","createdAt":"2026-01-01T00:00:00Z","status":"done","summary":"","notes":[],"refinements":[],"provider":""}],"versions":[],"nextStep":2}"#.utf8))
    check(legacy.intents[0].steps == nil, "legacy intent decodes")
}

// MARK: YouTube sources
check(YouTube.videoIDs(in: "summarize https://www.youtube.com/watch?v=4Go39b2Vq9I&pp=ugUEEgJlbtIHCQ%3D and https://youtu.be/qeMMnOiF51A?t=3") == ["4Go39b2Vq9I", "qeMMnOiF51A"], "youtube ids: watch + youtu.be")
check(YouTube.videoIDs(in: "youtube.com/watch?feature=x&v=abcdefghijk youtube.com/shorts/ABCDEFGHIJK https://www.youtube.com/watch?v=abcdefghijk") == ["abcdefghijk", "ABCDEFGHIJK"], "youtube ids: v= not first, shorts, dedupe")
check(YouTube.videoIDs(in: "https://example.com/watch?v=abcdefghijk youtube.com/watch?v=tooshort") == [], "youtube ids: ignore non-youtube and bad ids")
check(YouTube.apiKey(inWatchPage: #"x "INNERTUBE_API_KEY": "AIzaKEY_1" y"#) == "AIzaKEY_1", "innertube key extracted")
let ytXML = #"<?xml version="1.0"?><transcript><text start="0.1" dur="2">So, AI solved</text><text start="1.2" dur="2">a math problem &amp;#39;s here.</text><text start="9.0" dur="1">New &lt;b&gt;thought&lt;/b&gt;</text></transcript>"#
check(YouTube.transcript(fromXML: ytXML) == "So, AI solved a math problem 's here.\n\nNew thought", "transcript: entities, tags, pause paragraphs")
check(YouTube.transcript(fromXML: #"<timedtext><body><p t="0" d="1">one</p><p t="1500" d="1">two</p></body></timedtext>"#) == "one two", "transcript: srv3 cues")
let ytTracks = [YouTube.Track(language: "ar", auto: true, url: "a"), YouTube.Track(language: "en", auto: true, url: "b"), YouTube.Track(language: "en", auto: false, url: "c")]
check(YouTube.pick(ytTracks, languages: ["en"])?.url == "c", "tracks: human English first")
check(YouTube.pick(Array(ytTracks.prefix(2)), languages: ["fr", "en"])?.url == "b", "tracks: then auto in preferred language")
let srcPrompt = PromptBuilder.editPrompt(blocks: [], instruction: "summarize", sources: [SourceMaterial(url: "https://www.youtube.com/watch?v=x", title: "Talk", byline: "Chan · 9:54", kind: "YouTube transcript (en)", text: "hello world")])
check(srcPrompt.contains("SOURCE MATERIAL") && srcPrompt.contains("[S1] Talk — Chan · 9:54") && srcPrompt.contains("<<<\nhello world\n>>>"), "prompt includes fetched sources")
check(srcPrompt.range(of: "SOURCE MATERIAL")!.lowerBound < srcPrompt.range(of: "INSTRUCTION")!.lowerBound, "sources precede instruction")

// inline discussion
let withReply = try! EditPlanParser.parse(#"{"slug":"q","summary":"s","notes":[],"edits":[],"reply":"It means X."}"#)
check(withReply.reply == "It means X." && withReply.edits.isEmpty, "plan: reply decoded")
check(try! EditPlanParser.parse(#"{"slug":"q","summary":"s","notes":[],"edits":[]}"#).reply == "", "plan: missing reply defaults to empty")
let dp = PromptBuilder.discussPrompt(blocks: [Block(id: "b1", html: "<p>Alpha beta.</p>"), Block(id: "b2", html: "<p>Gamma.</p>")],
                                     focus: ["b2"], quote: "  Gamma. ",
                                     history: [.init(message: "Explain", reply: "It is a letter.", changed: ""),
                                               .init(message: "Shorter", reply: "Done.", changed: "Trimmed b2")],
                                     message: "Is it accurate?")
check(dp.contains("SELECTED PASSAGE (in [b2])\n«Gamma.»"), "discuss: quote and location")
check(dp.contains("Author: Explain\nYou: It is a letter.") && dp.contains("(You edited the document: Trimmed b2)"), "discuss: thread history")
check(dp.range(of: "EARLIER IN THIS THREAD")!.lowerBound < dp.range(of: "AUTHOR'S MESSAGE\nIs it accurate?")!.lowerBound, "discuss: history precedes message")
check(!PromptBuilder.discussPrompt(blocks: [], focus: [], quote: "x", history: [], message: "m").contains("EARLIER IN THIS THREAD"), "discuss: no history section when empty")
test("selection content requests write into the document") {
    let blocks = [Block(id: "b1", html: "<h2>Executives need two kinds of competence</h2>"),
                  Block(id: "b2", html: "<p>Leaders need technical judgment and organizational skill.</p>"),
                  Block(id: "b3", html: "<h2>Career progress</h2>")]
    let prompt = PromptBuilder.discussPrompt(blocks: blocks, focus: ["b1"], quote: "Executives need two kinds of competence",
                                            history: [], message: "say more about this")
    check(prompt.contains("AUTHOR'S MESSAGE\nsay more about this"), "selection expansion preserves the author's request")
    check(prompt.contains("[b2] <p>Leaders need technical judgment and organizational skill.</p>") &&
          prompt.contains("[b3] <h2>Career progress</h2>"), "expansion receives existing section content and its boundary")
    check(prompt.contains("Default to editing the document") && prompt.contains("when in doubt"),
          "selection threads bias toward document edits when ambiguous")
    check(prompt.contains("Return document edits; a reply alone") && prompt.contains("use insertAfter"),
          "content requests require insertions rather than a sidebar-only answer")
    check(prompt.contains("keep it as a heading") && prompt.contains("nearby existing block in that section"),
          "selected headings can be expanded after their existing section content")
    check(prompt.contains("explicitly asks for a reply without editing") && prompt.contains("is this accurate?"),
          "explicit reply-only requests and assessments retain discussion behavior")
    check(!prompt.contains("If the message is a question, or asks for an explanation"),
          "no conflicting rule routes all explanations to replies")
    let workspace = URL(fileURLWithPath: "/tmp/margins-prompt-test")
    for policy in AgentToolPolicy.allCases {
        let system = PromptBuilder.system(tools: AgentContext(policy: policy, workspace: workspace))
        check(system.contains("document is your primary output") && system.contains("substantive content in edits[].html") &&
              system.contains("When in doubt, prefer a tracked edit"),
              "document output contract applies with tools \(policy.rawValue)")
    }
    check(PromptBuilder.system.contains("An explicit request to answer without editing takes precedence"),
          "one-shot providers also honor reply-only requests")
}
var threaded = Intent(step: 3, text: "Explain")
threaded.thread = UUID(); threaded.quote = "Gamma."; threaded.anchor = "b2"; threaded.focus = ["b2"]; threaded.reply = "A letter."
var tdoc = MarginsDocument(); tdoc.intents = [threaded]
let tback = try! MarginsDocument.decode(try! tdoc.encoded())
let ti = tback.intents.first!
check(ti.thread == threaded.thread && ti.quote == "Gamma." && ti.anchor == "b2" && ti.focus == ["b2"] && ti.reply == "A letter.", "intent thread fields round-trip")
let legacyIntent = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"instruction","step":1,"text":"t","createdAt":"2024-01-01T00:00:00Z","status":"done","summary":"","notes":[],"refinements":[],"provider":""}"#
let isoDec = JSONDecoder(); isoDec.dateDecodingStrategy = .iso8601
let li = try! isoDec.decode(Intent.self, from: Data(legacyIntent.utf8))
check(li.thread == nil && li.reply == nil && li.focus == nil, "legacy intent decodes without thread fields")

// --- project folder ---
do {
    var d = MarginsDocument(html: "<p>x</p>")
    d.projectFolder = "/tmp/proj"
    let back = try JSONDecoder().decode(MarginsDocument.self, from: JSONEncoder().encode(d))
    check(back.projectFolder == "/tmp/proj", "projectFolder round-trips")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MarginsDocument(html: "<p>x</p>"))) as! [String: Any]
    legacy.removeValue(forKey: "projectFolder")
    let old = try JSONDecoder().decode(MarginsDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
    check(old.projectFolder == nil, "legacy doc decodes without projectFolder")
    var it = Intent(step: 1, text: "t", provider: "p"); it.files = ["a.swift"]
    let itBack = try JSONDecoder().decode(Intent.self, from: JSONEncoder().encode(it))
    check(itBack.files == ["a.swift"], "Intent.files round-trips")

    let ws = URL(fileURLWithPath: "/tmp/proj")
    let proj = PromptBuilder.system(tools: AgentContext(policy: .full, workspace: ws, project: true, onEvent: { _ in }, askPermission: { _ in .deny }))
    check(proj.contains("author's project at /tmp/proj") && proj.contains("implement features"), "system prompt: project wording")
    check(proj.contains("Full agent"), "system prompt: tells author to switch to Full agent when blocked")
    let scratch = PromptBuilder.system(tools: AgentContext(policy: .research, workspace: ws, onEvent: { _ in }, askPermission: { _ in .deny }))
    check(scratch.contains("belongs to this document") && scratch.contains("Project Folder"), "system prompt: scratch workspace wording")
    let dp = PromptBuilder.discussPrompt(blocks: [Block(id: "b1", html: "<p>todo</p>")], focus: ["b1"], quote: "todo",
                                         history: [], message: "implement this", sources: [])
    check(dp.contains("work outside the document"), "discussPrompt: outside-work bullet")

    check(ProjectChanges.paths(porcelainZ: " M a.txt\0?? new/b.txt\0R  c2.txt\0c.txt\0D  gone.txt\0") == ["a.txt", "new/b.txt", "c2.txt", "gone.txt"],
          "porcelain -z parsing incl. renames")

    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("margins-pc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    func sh(_ a: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", repo.path] + a
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit() }
    sh(["init", "-q"])
    try "one".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    try "dirty".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
    sh(["add", "."]); sh(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
    try "dirty2".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
    let before = ProjectChanges.snapshot(repo)
    check(before?.keys.sorted() == ["dirty.txt"], "snapshot lists pre-existing dirty file")
    Thread.sleep(forTimeInterval: 0.02)
    try "two".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
    try "new".write(to: repo.appendingPathComponent("src/new.swift"), atomically: true, encoding: .utf8)
    let after = ProjectChanges.snapshot(repo)
    check(after.map { ProjectChanges.changed(from: before!, to: $0) } == ["keep.txt", "src/new.swift"], "changed files exclude untouched dirty file")
    check(ProjectChanges.snapshot(FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID())")) == nil, "non-repo → nil")
} catch { check(false, "project folder tests threw \(error)") }

// --- unrestricted policy ---
do {
    let ws = URL(fileURLWithPath: "/tmp/ws")
    check(CodexExecProvider.policyArguments(.unrestricted).contains("danger-full-access"), "unrestricted: codex no sandbox")
    check(ClaudeCodeProvider.policyArguments(.unrestricted).contains("--dangerously-skip-permissions"), "unrestricted: claude skips permissions")
    check(AgentContext(policy: .unrestricted, workspace: ws).autoDecision(for: .delete) == .allowAlways, "unrestricted allows all")
    check(AgentToolPolicy.unrestricted.canWrite && AgentToolPolicy.full.canWrite && !AgentToolPolicy.research.canWrite, "canWrite")
    let u = PromptBuilder.system(tools: AgentContext(policy: .unrestricted, workspace: ws))
    check(u.contains("not sandboxed") && u.contains("Never use sudo"), "unrestricted prompt allows outside work")
    let f = PromptBuilder.system(tools: AgentContext(policy: .full, workspace: ws))
    check(f.contains("Never modify anything outside it") && f.contains("Unrestricted"), "full prompt points to Unrestricted")
}

let sem = DispatchSemaphore(value: 0)
Task {
    let r = try! await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: "hello")
    check(r.stdout == "hello" && r.status == 0, "process runner stdin/stdout")
    let lines = TextCollector()
    let r2 = try! await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: "a\nb\nc", onLine: { lines.append("[\($0)]") })
    check(r2.stdout == "a\nb\nc" && lines.text == "[a][b][c]", "process runner streams lines")
    sem.signal()
}
sem.wait()

test("font preferences round trip and CSS stacks") {
    let defaults = FontPreferences()
    check(defaults.documentFontCSS == FontPreferences.defaultCSSStack, "default document font stack")
    check(defaults.uiFontCSS == FontPreferences.defaultCSSStack, "default UI font stack")
    check(FontPreferences.cssFontFamily(for: FontPreferences.systemSerif).contains("ui-serif"), "serif stack")
    check(FontPreferences.cssFontFamily(for: FontPreferences.systemRounded).contains("ui-rounded"), "rounded stack")
    check(FontPreferences.cssFontFamily(for: FontPreferences.systemMonospace).contains("ui-monospace"), "monospace stack")
    let custom = FontPreferences(documentFont: "Charter", uiFont: "Helvetica \"Neue\"")
    let decoded = try JSONDecoder().decode(FontPreferences.self, from: JSONEncoder().encode(custom))
    check(decoded == custom, "font preferences round trip")
    check(custom.documentFontCSS.hasPrefix("\"Charter\","), "custom document font quoted")
    check(custom.uiFontCSS.hasPrefix("\"Helvetica \\\"Neue\\\"\","), "quotes escaped in CSS font family")
}


let bundledThemesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Margins/Resources/Themes")

test("theme JSON decode/encode round trip") {
    let theme = MarginsTheme.builtInDefault
    let decoded = try JSONDecoder().decode(MarginsTheme.self, from: JSONEncoder().encode(theme))
    check(decoded == theme, "full theme survives round trip")
    check(decoded.supportedSchemes == [.light, .dark] && decoded.modeBadge == nil, "dual-mode theme has no badge")
    let payload = theme.resolved(for: .dark).editorPayload
    check(payload.vars["--panel"] == "#22201D" && payload.vars["--thread-acc"] == "#E5A93B", "palette maps to editor CSS vars")
    check(payload.colorScheme == "dark" && payload.sheetStyle == "card" && payload.cornerRadius == 8, "chrome in editor payload")
}

test("partial palettes fall back to default tokens") {
    let json = ##"{"id":"p","name":"Partial","chrome":{"sheetStyle":"seamless","cornerRadius":99},"light":{"accent":"#123456","ink":"oops","bogus":"#FFFFFF"},"dark":{"sheetBg":"#000"}}"##
    let (theme, warnings) = try ThemeLoader.decode(Data(json.utf8))
    let light = theme.resolvedPalette(for: .light)
    check(light.isComplete, "resolved palette is complete")
    check(light["accent"] == "#123456", "own token wins")
    check(light["ink"] == MarginsTheme.builtInDefault.light?["ink"], "invalid hex falls back to default")
    check(light["bogus"] == nil, "unknown tokens are dropped")
    check(warnings.count == 1 && warnings[0].contains("ink"), "invalid hex is reported")
    check(theme.resolvedPalette(for: .dark)["sheetBg"] == "#000" && theme.resolvedPalette(for: .dark)["ink"] == "#EFECE6", "dark partial merges")
    check(theme.chrome.sheetStyle == .seamless && theme.chrome.cornerRadius == 24, "chrome decoded and clamped")
    let bare = try JSONDecoder().decode(ThemeChrome.self, from: Data("{}".utf8))
    check(bare == ThemeChrome(), "chrome defaults")
}

test("single-mode themes resolve the default counterpart") {
    let (dark, _) = try ThemeLoader.decode(Data(##"{"id":"d","name":"D","dark":{"ink":"#EEEEEE"}}"##.utf8))
    check(dark.supportedSchemes == [.dark] && dark.modeBadge == "Dark only", "dark-only detected")
    check(dark.resolvedPalette(for: .light) == MarginsTheme.builtInDefault.light, "light falls back to default light")
    let (light, _) = try ThemeLoader.decode(Data(##"{"id":"l","name":"L","light":{}}"##.utf8))
    check(light.modeBadge == "Light only", "light-only detected")
    check(AppearanceMode.system.resolve(systemScheme: .dark) == .dark && AppearanceMode.light.resolve(systemScheme: .dark) == .light, "appearance override")
}

test("hex validation and contrast") {
    check(ThemeColor.isValidHex("#abc") && ThemeColor.isValidHex("#A1B2C3") && ThemeColor.isValidHex("#A1B2C3FF"), "valid hex forms")
    check(!ThemeColor.isValidHex("A1B2C3") && !ThemeColor.isValidHex("#GGGGGG") && !ThemeColor.isValidHex("#12345"), "invalid hex forms")
    check(abs((ThemeColor.contrastRatio("#000000", "#FFFFFF") ?? 0) - 21) < 0.01, "black on white is 21:1")
}

test("malformed theme files are skipped during directory load") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("a-broken.json"))
    try Data(##"{"id":"","name":"x","light":{}}"##.utf8).write(to: dir.appendingPathComponent("b-noid.json"))
    try Data(##"{"id":"n","name":"No palettes"}"##.utf8).write(to: dir.appendingPathComponent("c-empty.json"))
    try Data(##"{"id":"ok","name":"Okay","dark":{"accent":"#FF0000"}}"##.utf8).write(to: dir.appendingPathComponent("d-ok.json"))
    try Data(##"{"id":"ok","name":"Dup","dark":{}}"##.utf8).write(to: dir.appendingPathComponent("e-dup.json"))
    try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    var logs: [String] = []
    let themes = ThemeLoader.loadDirectory(dir) { logs.append($0) }
    check(themes.map(\.id) == ["ok"], "only the valid theme loads")
    check(logs.count == 4, "each bad file is logged")
    let merged = ThemeCatalog.merge(builtIn: [], user: themes + [MarginsTheme(id: MarginsTheme.defaultID, name: "Shadow", light: ThemePalette())])
    check(merged.map(\.id) == [MarginsTheme.defaultID, "ok"], "default is always present and cannot be shadowed")
    check(ThemeCatalog.theme(id: "missing", in: merged).id == MarginsTheme.defaultID, "unknown selection falls back to default")
}

test("theme font precedence") {
    let fonts = ThemeFonts(documentFont: FontPreferences.systemSerif, uiFont: "")
    let effective = FontPreferences(documentFont: "", uiFont: "").effective(with: fonts)
    check(effective.documentFont == FontPreferences.systemSerif && effective.uiFont == "", "theme suggestion applies when user has no choice")
    check(FontPreferences(documentFont: "Charter").effective(with: fonts).documentFont == "Charter", "explicit user font wins")
    check(FontPreferences().effective(with: nil) == FontPreferences(), "system default without theme")
    let sans = FontPreferences(documentFont: FontPreferences.systemSans).effective(with: fonts)
    check(sans.documentFont == FontPreferences.systemSans && sans.documentFontCSS == FontPreferences.defaultCSSStack, "explicit system sans overrides a serif theme")
    check(FontPreferences.source(user: "", theme: "Avenir") == .theme && FontPreferences.source(user: "X", theme: "Y") == .user, "font source")
}

test("bundled themes are complete, valid, and legible") {
    let ids = ["warm-editorial", "frosted-studio", "swiss-studio", "botanical-ink", "ink-slate"]
    var logs: [String] = []
    let themes = ThemeLoader.loadDirectory(bundledThemesDir) { logs.append($0) }
    check(Set(themes.map(\.id)) == Set(ids) && logs.isEmpty, "all five built-in themes load cleanly: \(logs)")
    for theme in themes {
        check(!theme.name.isEmpty && theme.author == "Margins", "\(theme.id) has name and author")
        for scheme in ThemeColorScheme.allCases {
            guard let palette = theme.palette(for: scheme) else { check(false, "\(theme.id) missing \(scheme)"); continue }
            check(palette.isComplete && palette.invalidTokens.isEmpty, "\(theme.id) \(scheme) palette complete and valid")
            let sheet = ThemeColor.contrastRatio(palette["ink"] ?? "", palette["sheetBg"] ?? "") ?? 0
            let rail = ThemeColor.contrastRatio(palette["ink"] ?? "", palette["railBg"] ?? "") ?? 0
            check(sheet >= 4.5 && rail >= 4.5, "\(theme.id) \(scheme) ink contrast \(sheet) / \(rail)")
            check(!palette.tokens.values.contains { $0.lowercased() == "#4f46e5" }, "\(theme.id) retires indigo")
        }
    }
    check(themes.first { $0.id == MarginsTheme.defaultID } == MarginsTheme.builtInDefault, "bundled default matches code default")
    check(themes.first { $0.id == "frosted-studio" }?.chrome.sidebarVibrancy == true, "frosted uses vibrancy")
    check(themes.first { $0.id == "swiss-studio" }?.chrome.sheetStyle == .seamless, "swiss is seamless")
}
test("per-machine project folder store and migration") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-pf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let storeURL = dir.appendingPathComponent("project-folders.json")
    let store = ProjectFolderStore(fileURL: storeURL)
    let docID = UUID()
    check(store.folder(for: docID) == nil, "empty initially")
    check(store.folder(for: docID, fallbackDocumentFolder: "/legacy/repo") == "/legacy/repo", "falls back to legacy document field")

    store.migrateIfNeeded(docID: docID, legacyFolder: "/legacy/repo")
    check(store.folder(for: docID) == "/legacy/repo", "migrates legacy folder into local store")

    // Reopen from disk to verify persistence.
    let reloaded = ProjectFolderStore(fileURL: storeURL)
    check(reloaded.folder(for: docID) == "/legacy/repo", "persisted across instances")

    reloaded.setFolder("/machine-b/repo", for: docID)
    check(reloaded.folder(for: docID, fallbackDocumentFolder: "/legacy/repo") == "/machine-b/repo", "local mapping overrides document field")

    reloaded.setFolder(nil, for: docID)
    check(reloaded.folder(for: docID) == nil, "clearing removes mapping")
    check(reloaded.recentFolders() == ["/machine-b/repo", "/legacy/repo"], "clearing document mapping preserves recents")
}

test("project folder store recent MRU, cap, clearing, and legacy JSON migration") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-pf-recent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Legacy flat [String: String] file migrates and seeds recents.
    let legacyURL = dir.appendingPathComponent("legacy-project-folders.json")
    let docA = UUID()
    let docB = UUID()
    let legacyJSON = try JSONEncoder().encode([
        docA.uuidString: "/tmp/work/alpha",
        docB.uuidString: "/tmp/work/beta",
    ])
    try legacyJSON.write(to: legacyURL, options: .atomic)

    let migrated = ProjectFolderStore(fileURL: legacyURL)
    check(migrated.folder(for: docA) == "/tmp/work/alpha", "legacy doc A preserved")
    check(migrated.folder(for: docB) == "/tmp/work/beta", "legacy doc B preserved")
    check(migrated.recentFolders() == ["/tmp/work/alpha", "/tmp/work/beta"], "legacy values seed unique recents")

    // MRU ordering, deduplication, and 10-item cap.
    let storeURL = dir.appendingPathComponent("project-folders.json")
    let store = ProjectFolderStore(fileURL: storeURL)
    var changeCount = 0
    let token = NotificationCenter.default.addObserver(
        forName: ProjectFolderStore.didChangeNotification, object: store, queue: nil
    ) { _ in changeCount += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    let docID = UUID()
    for i in 1...12 {
        store.setFolder("/repos/proj-\(i)", for: docID)
    }
    check(changeCount == 12, "didChangeNotification posted on each save")
    check(store.recentFolders().count == 10, "recent list capped at 10")
    check(store.recentFolders().first == "/repos/proj-12", "most recent folder at index 0")
    check(!store.recentFolders().contains("/repos/proj-1"), "oldest folders evicted beyond 10")

    // Re-selecting an existing folder moves it to index 0 without duplicating.
    store.setFolder("/repos/proj-5/", for: docID)
    check(store.recentFolders().count == 10, "re-selecting deduplicates standardized path")
    check(store.recentFolders().first == "/repos/proj-5", "re-selected folder promoted to index 0")

    // Removing one recent entry leaves others intact.
    store.removeRecentFolder("/repos/proj-12")
    check(!store.recentFolders().contains("/repos/proj-12"), "removeRecentFolder removes entry")
    check(store.recentFolders().count == 9, "removeRecentFolder reduces count by 1")

    // Clearing recents preserves document mappings and persists.
    store.clearRecentFolders()
    check(store.recentFolders().isEmpty, "clearRecentFolders empties recents")
    check(store.folder(for: docID) == "/repos/proj-5", "clearRecentFolders leaves document mappings intact")

    let reopened = ProjectFolderStore(fileURL: storeURL)
    check(reopened.recentFolders().isEmpty, "cleared recents persist across reload")
    check(reopened.folder(for: docID) == "/repos/proj-5", "document mapping persists after clearRecentFolders")

    // Missing directory filtering lazily prunes in memory and persists on next save.
    let realDir = dir.appendingPathComponent("real-repo")
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let missingDir = dir.appendingPathComponent("deleted-repo")
    reopened.setFolder(missingDir.path, for: docID)
    reopened.setFolder(realDir.path, for: docID)
    check(reopened.existingRecentFolders() == [realDir.standardizedFileURL.path], "existingRecentFolders filters missing paths")
    reopened.setFolder(nil, for: docID)
    let afterPrune = ProjectFolderStore(fileURL: storeURL)
    check(afterPrune.recentFolders() == [realDir.standardizedFileURL.path], "pruned missing paths dropped on next save")

    // Display label disambiguation when folder names collide.
    let urls = [
        URL(fileURLWithPath: "/Users/dev/work/app"),
        URL(fileURLWithPath: "/Users/dev/personal/app"),
        URL(fileURLWithPath: "/Users/dev/margins"),
    ]
    check(ProjectFolderStore.displayLabel(for: urls[2], among: urls) == "margins", "unique name uses lastPathComponent")
    check(ProjectFolderStore.displayLabel(for: urls[0], among: urls).contains("/Users/dev/work/app"), "duplicate name includes path")
}

test("agent notification coordinator suppression, formatting, and unbundled safety") {
    final class MockDelivery: AgentNotificationDelivery {
        var isAvailable: Bool
        var authRequests = 0
        var delivered: [AgentNotificationPayload] = []
        var clearedURLs: [URL] = []

        init(isAvailable: Bool = true) { self.isAvailable = isAvailable }
        func requestAuthorization() { authRequests += 1 }
        func deliver(_ payload: AgentNotificationPayload) { delivered.append(payload) }
        func removeDelivered(forDocumentURL url: URL) { clearedURLs.append(url) }
    }

    let suiteName = "margins-notify-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let docURL = URL(fileURLWithPath: "/tmp/Notes.margins")
    let intentID = UUID()
    let threadID = UUID()

    // Unbundled environment is a safe no-op.
    let unbundledDelivery = MockDelivery(isAvailable: false)
    let unbundled = AgentNotificationCoordinator(delivery: unbundledDelivery, defaults: defaults)
    unbundled.requestAuthorizationIfNeeded()
    unbundled.notify(
        documentURL: docURL, step: 1, intentID: intentID,
        outcome: .completed(hasEdits: true, summary: "Tightened intro", slug: "tighten intro", reply: ""),
        isDocumentFocused: false
    )
    unbundled.clearNotifications(forDocumentURL: docURL)
    check(unbundledDelivery.authRequests == 0, "unbundled skips authorization")
    check(unbundledDelivery.delivered.isEmpty, "unbundled skips delivery")
    check(unbundledDelivery.clearedURLs.isEmpty, "unbundled skips clearing")

    // Bundled environment: lazy auth, focus suppression, cancellation suppression, and formatting.
    let delivery = MockDelivery(isAvailable: true)
    let coordinator = AgentNotificationCoordinator(delivery: delivery, defaults: defaults)
    coordinator.requestAuthorizationIfNeeded()
    coordinator.requestAuthorizationIfNeeded()
    check(delivery.authRequests == 1, "lazy authorization requested once")

    // Suppressed while document is focused (default onlyWhenInBackground = true).
    coordinator.notify(
        documentURL: docURL, step: 1, intentID: intentID,
        outcome: .completed(hasEdits: true, summary: "Tightened intro", slug: "tighten intro", reply: ""),
        isDocumentFocused: true
    )
    check(delivery.delivered.isEmpty, "suppressed while document is focused")

    // Suppressed when cancelled even if unfocused.
    coordinator.notify(
        documentURL: docURL, step: 1, intentID: intentID,
        outcome: .failed(error: "Stopped."), wasCancelled: true, isDocumentFocused: false
    )
    check(delivery.delivered.isEmpty, "suppressed on cancellation")

    // Delivered for edits when unfocused; uses summary and carries IDs.
    coordinator.notify(
        documentURL: docURL, step: 2, intentID: intentID, threadID: nil,
        outcome: .completed(hasEdits: true, summary: "Added rollout timeline", slug: "add timeline", reply: ""),
        isDocumentFocused: false
    )
    check(delivery.delivered.count == 1, "delivers edit notification when unfocused")
    check(delivery.delivered[0].title == "Notes", "title uses document name without extension")
    check(delivery.delivered[0].body == "Added rollout timeline", "edit notification body uses summary")
    check(delivery.delivered[0].playSound == true, "sound defaults to on")
    check(delivery.delivered[0].intentID == intentID, "payload preserves intentID")

    // Falls back to slug when summary is empty, and truncates long reply-only notifications.
    let longReply = String(repeating: "word ", count: 60)
    coordinator.notify(
        documentURL: docURL, step: 3, intentID: intentID, threadID: threadID,
        outcome: .completed(hasEdits: false, summary: "", slug: "reply slug", reply: longReply),
        isDocumentFocused: false
    )
    check(delivery.delivered.count == 2, "delivers reply-only notification")
    check(delivery.delivered[1].threadID == threadID, "payload preserves threadID")
    check(delivery.delivered[1].body.count <= 180 && delivery.delivered[1].body.hasSuffix("…"), "long reply truncated cleanly")

    // Failure notification includes failure indicator and error message.
    coordinator.notify(
        documentURL: docURL, step: 4, intentID: intentID,
        outcome: .failed(error: "Provider timed out"),
        isDocumentFocused: false
    )
    check(delivery.delivered.count == 3, "delivers failure notification")
    check(delivery.delivered[2].title == "Notes · Agent failed", "failure title includes indicator")
    check(delivery.delivered[2].body == "Provider timed out", "failure body uses error message")

    // Respects preferences: notify even when focused if onlyWhenInBackground = false, sound off, and master disable.
    defaults.set(false, forKey: AgentNotificationPreferences.onlyWhenInBackgroundKey)
    defaults.set(false, forKey: AgentNotificationPreferences.playSoundKey)
    coordinator.notify(
        documentURL: docURL, step: 5, intentID: intentID,
        outcome: .completed(hasEdits: true, summary: "", slug: "polish conclusion", reply: ""),
        isDocumentFocused: true
    )
    check(delivery.delivered.count == 4, "delivers while focused when background-only is off")
    check(delivery.delivered[3].body == "polish conclusion", "falls back to slug when summary is empty")
    check(delivery.delivered[3].playSound == false, "respects playSound preference")

    defaults.set(false, forKey: AgentNotificationPreferences.notifyOnFinishKey)
    coordinator.notify(
        documentURL: docURL, step: 6, intentID: intentID,
        outcome: .completed(hasEdits: true, summary: "Ignored", slug: "ignored", reply: ""),
        isDocumentFocused: false
    )
    check(delivery.delivered.count == 4, "master toggle suppresses notifications")

    coordinator.clearNotifications(forDocumentURL: docURL)
    check(delivery.clearedURLs == [docURL], "clearNotifications forwards document URL")
}

test("file change watcher detects external atomic writes and ignores self writes") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("note.margins")
    let initial = Data("{\"v\":1}".utf8)
    try initial.write(to: file, options: .atomic)

    final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
    }

    let changedSem = DispatchSemaphore(value: 0)
    let collector = URLCollector()

    let watcher = FileChangeWatcher(debounceInterval: 0.05) { url in
        collector.append(url)
        changedSem.signal()
    }
    watcher.watch(file)
    defer { watcher.stop() }

    // Self-write should NOT trigger onExternalChange.
    let selfData = Data("{\"v\":2}".utf8)
    watcher.markSelfWrite(selfData)
    try selfData.write(to: file, options: .atomic)
    let selfWait = changedSem.wait(timeout: .now() + 0.2)
    check(selfWait == .timedOut, "self-write ignored by watcher")

    // External atomic write SHOULD trigger onExternalChange.
    let externalData = Data("{\"v\":3}".utf8)
    try externalData.write(to: file, options: .atomic)
    let extWait = changedSem.wait(timeout: .now() + 2.0)
    check(extWait == .success, "external atomic write detected")
    check(collector.count == 1, "exactly one external change notification")
}

// --- Phase 1: Google OAuth & Drive backend tests ---

actor MockHTTPClient: HTTPClient {
    private var handlers: [@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)]
    private var recordedRequests: [URLRequest] = []

    init(_ handlers: [@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)]) {
        self.handlers = handlers
    }

    func requests() -> [URLRequest] { recordedRequests }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !handlers.isEmpty else {
            throw SyncError.invalidResponse("Unexpected HTTP request: \(request.url?.absoluteString ?? "")")
        }
        let handler = handlers.removeFirst()
        return try await handler(request)
    }

    nonisolated static func jsonResponse(_ obj: Any, status: Int = 200, url: URL = URL(string: "https://example.com")!) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, resp)
    }
}

test("Google desktop client in a distribution build") {
    let bundled = GoogleOAuthConfig(clientID: "release", clientSecret: "release-value")
    check(GoogleOAuthConfig().usingDefault(bundled) == bundled, "a new install uses the complete bundled client")
    let own = GoogleOAuthConfig(clientID: "custom")
    check(own.usingDefault(bundled) == own, "custom IDs never inherit another client's secret")
    check(GoogleOAuthConfig(clientID: "release").usingDefault(bundled) == bundled, "existing matching ID uses the bundled secret")
    check(GoogleOAuthConfig(clientID: "  release \n", clientSecret: "  ").usingDefault(bundled) == bundled, "whitespace-padded matching ID uses the bundled secret")
    check(GoogleOAuthConfig(clientID: "  custom  ", clientSecret: " secret ").usingDefault(bundled) == GoogleOAuthConfig(clientID: "custom", clientSecret: "secret"), "custom client ID and secret are trimmed")
    let override = GoogleOAuthConfig(clientID: "release", clientSecret: "override")
    check(override.usingDefault(bundled) == override, "explicit client secret takes precedence")
}

test("PKCE challenge and loopback callback parser") {
    // RFC 7636 Appendix B test vector:
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    check(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 S256 challenge matches")

    let ok = LoopbackOAuthServer.parseCallbackRequest("GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", expectedState: "xyz")
    check((try? ok.get()) == "abc123", "valid callback extracts code")

    let mismatch = LoopbackOAuthServer.parseCallbackRequest("GET /callback?code=abc&state=wrong HTTP/1.1\r\n", expectedState: "xyz")
    check((try? mismatch.get()) == nil, "state mismatch rejected")

    let err = LoopbackOAuthServer.parseCallbackRequest("GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n", expectedState: "xyz")
    check((try? err.get()) == nil, "oauth error rejected")
}

let oauthSem = DispatchSemaphore(value: 0)
Task {
    // End-to-end loopback socket test
    do {
        let server = try LoopbackOAuthServer()
        check(server.port > 0, "loopback binds ephemeral port")
        let redirect = server.redirectURI
        let waitTask = Task { try await server.waitForCode(expectedState: "st42", timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cbURL = URL(string: "\(redirect)?code=auth-code-99&state=st42")!
        let (body, resp) = try await URLSession.shared.data(from: cbURL)
        check((resp as? HTTPURLResponse)?.statusCode == 200, "loopback returns HTTP 200")
        check(String(decoding: body, as: UTF8.self).contains("Signed in to Google Drive"), "loopback returns confirmation HTML")
        let code = try await waitTask.value
        check(code == "auth-code-99", "loopback delivers authorization code")
    } catch {
        check(false, "loopback server test threw \(error)")
    }

    // OAuth client authorization URL, code exchange, refresh, and disconnect
    do {
        let store = MemoryTokenStore()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let http = MockHTTPClient([
            { req in
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                check(body.contains("grant_type=authorization_code"), "code exchange grant_type")
                check(body.contains("code_verifier=ver123"), "code exchange includes PKCE verifier")
                return MockHTTPClient.jsonResponse([
                    "access_token": "tok-1",
                    "refresh_token": "ref-1",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                    "scope": GoogleOAuthConfig.driveFileScope,
                ])
            },
            { req in
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                check(body.contains("grant_type=refresh_token"), "refresh grant_type")
                check(body.contains("refresh_token=ref-1"), "refresh sends stored refresh token")
                return MockHTTPClient.jsonResponse([
                    "access_token": "tok-2",
                    "expires_in": 3600,
                ])
            },
            { req in
                check(req.url?.absoluteString == GoogleOAuthConfig.revokeEndpoint, "revoke endpoint called")
                return MockHTTPClient.jsonResponse([:])
            },
        ])
        let oauth = GoogleOAuthClient(
            config: GoogleOAuthConfig(clientID: "test-client-id"),
            tokenStore: store,
            http: http,
            now: { fixedNow }
        )
        let pkce = PKCE(codeVerifier: "ver123", state: "st1")
        let authURL = try await oauth.authorizationURL(redirectURI: "http://127.0.0.1:9999/callback", pkce: pkce)
        let authStr = authURL.absoluteString
        check(authStr.contains("scope=https://www.googleapis.com/auth/drive.file"), "auth URL uses drive.file scope")
        check(authStr.contains("code_challenge_method=S256"), "auth URL uses S256 PKCE")
        check(authStr.contains("access_type=offline"), "auth URL requests offline refresh token")

        let exchanged = try await oauth.exchangeCode("code-1", redirectURI: "http://127.0.0.1:9999/callback", codeVerifier: "ver123")
        check(exchanged.accessToken == "tok-1" && exchanged.refreshToken == "ref-1", "tokens stored from exchange")
        let cachedToken = try await oauth.validAccessToken()
        check(cachedToken == "tok-1", "returns cached non-expired token")

        let refreshed = try await oauth.validAccessToken(forceRefresh: true)
        check(refreshed == "tok-2", "forceRefresh fetches new access token")
        check(store.load()?.refreshToken == "ref-1", "refresh preserves existing refresh token when omitted")

        await oauth.disconnect()
        check(store.load() == nil, "disconnect clears stored tokens")
    } catch {
        check(false, "oauth client test threw \(error)")
    }

    // GoogleDriveBackend: ensureRootFolder (create), upload, listChanges pagination, 401 retry
    do {
        let docID = UUID()
        final class RefreshRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            func record(_ v: Bool) { lock.lock(); values.append(v); lock.unlock() }
            var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let recorder = RefreshRecorder()
        let http = MockHTTPClient([
            // ensureRootFolder: search returns empty
            { req in
                check(req.url?.absoluteString.contains("marginsRoot") == true, "root folder query uses appProperties")
                return MockHTTPClient.jsonResponse(["files": []])
            },
            // ensureRootFolder: creates folder
            { req in
                check(req.httpMethod == "POST", "creates folder via POST")
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                check(body.contains("\"name\":\"Margins\"") || body.contains("\"name\" : \"Margins\""), "folder named Margins")
                return MockHTTPClient.jsonResponse(["id": "folder-1", "name": "Margins"])
            },
            // upload: first attempt returns 401, triggers forceRefresh retry
            { _ in
                MockHTTPClient.jsonResponse(["error": "unauthorized"], status: 401)
            },
            // upload: retry succeeds
            { req in
                check(req.httpMethod == "POST", "new upload uses POST")
                check(req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token", "retry uses refreshed token")
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                check(body.contains(docID.uuidString), "multipart metadata tags marginsDocId")
                return MockHTTPClient.jsonResponse([
                    "id": "file-1",
                    "name": "Doc.margins",
                    "headRevisionId": "rev-1",
                    "appProperties": ["marginsDocId": docID.uuidString],
                ])
            },
            // listChanges page 1
            { _ in
                MockHTTPClient.jsonResponse([
                    "nextPageToken": "p2",
                    "changes": [[
                        "fileId": "file-1",
                        "removed": false,
                        "file": [
                            "id": "file-1",
                            "name": "Doc.margins",
                            "headRevisionId": "rev-2",
                            "parents": ["folder-1"],
                            "appProperties": ["marginsDocId": docID.uuidString],
                        ],
                    ]],
                ])
            },
            // listChanges page 2
            { _ in
                MockHTTPClient.jsonResponse([
                    "newStartPageToken": "tok-next",
                    "changes": [[
                        "fileId": "file-2",
                        "removed": true,
                    ]],
                ])
            },
        ])
        let drive = GoogleDriveBackend(tokenProvider: { force in
            recorder.record(force)
            return force ? "fresh-token" : "initial-token"
        }, http: http)

        let folderID = try await drive.ensureRootFolder()
        check(folderID == "folder-1", "created root folder ID returned")

        let uploaded = try await drive.upload(data: Data("{\"html\":\"<h1>Hi</h1>\"}".utf8), name: "Doc.margins", docID: docID, folderID: folderID, existingFileID: nil)
        check(uploaded.id == "file-1" && uploaded.headRevisionId == "rev-1" && uploaded.docID == docID, "upload parses RemoteFile")
        check(recorder.all.contains(true), "401 triggered forceRefresh")

        let page = try await drive.listChanges(pageToken: "p1", folderID: folderID)
        check(page.newStartPageToken == "tok-next", "changes pagination captures newStartPageToken")
        check(page.changes.count == 2, "changes combines all pages")
        check(page.changes[0].file?.headRevisionId == "rev-2" && page.changes[1].removed, "changes parse updates and removals")
    } catch {
        check(false, "drive backend test threw \(error)")
    }

    oauthSem.signal()
}
oauthSem.wait()

// --- Phase 2: SyncIndex and SyncEngine tests ---

actor InMemorySyncBackend: SyncBackend {
    struct Stored {
        var meta: RemoteFile
        var data: Data
    }
    var offline = false
    var folderID = "drive-folder-1"
    var files: [String: Stored] = [:]
    var changeLog: [RemoteChange] = []
    var revCounter = 0

    func setOffline(_ v: Bool) { offline = v }

    func seedRemote(doc: MarginsDocument, name: String) throws -> RemoteFile {
        revCounter += 1
        let id = "remote-\(revCounter)"
        let data = try doc.encoded()
        let meta = RemoteFile(id: id, name: name, docID: doc.id, headRevisionId: "rev-\(revCounter)",
                              modifiedTime: Date(), trashed: false, size: Int64(data.count))
        files[id] = Stored(meta: meta, data: data)
        changeLog.append(RemoteChange(fileId: id, removed: false, file: meta))
        return meta
    }

    func updateRemote(fileID: String, doc: MarginsDocument, newName: String? = nil) throws -> RemoteFile {
        guard var stored = files[fileID] else { throw SyncError.httpError(404, "missing") }
        revCounter += 1
        let data = try doc.encoded()
        stored.meta.headRevisionId = "rev-\(revCounter)"
        if let newName { stored.meta.name = newName }
        stored.meta.modifiedTime = Date()
        stored.meta.size = Int64(data.count)
        stored.data = data
        files[fileID] = stored
        changeLog.append(RemoteChange(fileId: fileID, removed: false, file: stored.meta))
        return stored.meta
    }

    func fileCount() -> Int { files.count }
    func fileMeta(_ id: String) -> RemoteFile? { files[id]?.meta }

    func ensureRootFolder() async throws -> String {
        if offline { throw SyncError.offline("simulated offline") }
        return folderID
    }

    func listFiles(folderID: String) async throws -> [RemoteFile] {
        if offline { throw SyncError.offline("simulated offline") }
        return files.values.map(\.meta).filter { !$0.trashed }
    }

    func getStartPageToken() async throws -> String {
        if offline { throw SyncError.offline("simulated offline") }
        return "\(changeLog.count)"
    }

    func listChanges(pageToken: String, folderID: String) async throws -> ChangesPage {
        if offline { throw SyncError.offline("simulated offline") }
        let idx = Int(pageToken) ?? 0
        let slice = idx < changeLog.count ? Array(changeLog[idx...]) : []
        return ChangesPage(changes: slice, newStartPageToken: "\(changeLog.count)")
    }

    func getMetadata(fileID: String) async throws -> RemoteFile? {
        if offline { throw SyncError.offline("simulated offline") }
        return files[fileID]?.meta
    }

    func download(fileID: String) async throws -> Data {
        if offline { throw SyncError.offline("simulated offline") }
        guard let stored = files[fileID] else { throw SyncError.httpError(404, "not found") }
        return stored.data
    }

    func upload(data: Data, name: String, docID: UUID, folderID: String, existingFileID: String?) async throws -> RemoteFile {
        if offline { throw SyncError.offline("simulated offline") }
        revCounter += 1
        let id = existingFileID ?? "remote-\(revCounter)"
        let meta = RemoteFile(id: id, name: name, docID: docID, headRevisionId: "rev-\(revCounter)",
                              modifiedTime: Date(), trashed: false, size: Int64(data.count))
        files[id] = Stored(meta: meta, data: data)
        changeLog.append(RemoteChange(fileId: id, removed: false, file: meta))
        return meta
    }

    func rename(fileID: String, newName: String) async throws -> RemoteFile {
        if offline { throw SyncError.offline("simulated offline") }
        guard var stored = files[fileID] else { throw SyncError.httpError(404, "not found") }
        stored.meta.name = newName
        files[fileID] = stored
        return stored.meta
    }

    func delete(fileID: String) async throws {
        if offline { throw SyncError.offline("simulated offline") }
        files.removeValue(forKey: fileID)
        changeLog.append(RemoteChange(fileId: fileID, removed: true, file: nil))
    }
}

test("SyncIndex round trip and recency sorting") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-idx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let idxURL = dir.appendingPathComponent("sync-index.json")
    let d1 = UUID()
    let d2 = UUID()
    var index = SyncIndex(folderID: "f1", startPageToken: "10", lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000))
    index.setEntry(SyncEntry(docID: d1, driveFileId: "r1", lastSyncedRevision: "rev1", filename: "Older.margins", title: "Older", modifiedAt: Date(timeIntervalSince1970: 1000), state: .synced))
    index.setEntry(SyncEntry(docID: d2, driveFileId: "r2", lastSyncedRevision: "rev2", filename: "Newer.margins", title: "Newer", modifiedAt: Date(timeIntervalSince1970: 2000), state: .conflict, conflictFilename: "Newer (Conflict).margins"))
    try index.save(to: idxURL)

    let loaded = SyncIndex.load(from: idxURL)
    check(loaded == index, "SyncIndex round trips identically")
    check(loaded.sortedByRecency.map(\.docID) == [d2, d1], "sortedByRecency puts newest first")
    check(loaded.conflictCount == 1, "conflictCount counts conflict entries")
    check(loaded.entry(forDriveFileId: "r1")?.docID == d1, "lookup by driveFileId")
}

let syncSem = DispatchSemaphore(value: 0)
Task {
    // 1. Initial upload, rename in place without duplicate, and incremental pull with Markdown regeneration
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-sync-1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemorySyncBackend()
        let fixedDate = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let engine = SyncEngine(
            backend: backend,
            documentsFolder: dir,
            indexURL: dir.appendingPathComponent("sync-index.json"),
            hostName: "Studio.local",
            now: { fixedDate }
        )

        var doc = MarginsDocument()
        doc.snapshot(html: "<h1>Untitled</h1><p>Draft</p>", slug: "init", author: .you)
        let untitledURL = dir.appendingPathComponent("Untitled.margins")
        try doc.encoded().write(to: untitledURL, options: .atomic)

        let status1 = await engine.syncAll(uploadExistingLocal: true)
        if case .synced = status1 { check(true, "initial sync succeeds") } else { check(false, "expected synced, got \(status1)") }
        let fileCount1 = await backend.fileCount()
        check(fileCount1 == 1, "one file uploaded to Drive")
        let entry1 = await engine.currentIndex().entry(for: doc.id)
        check(entry1?.driveFileId != nil && entry1?.state == .synced, "index tracks driveFileId and synced state")

        // Rename Untitled.margins -> Roadmap.margins (same doc.id)
        doc.snapshot(html: "<h1>Roadmap</h1><p>Updated</p>", slug: "rename", author: .you)
        let renamedURL = dir.appendingPathComponent("Roadmap.margins")
        try FileManager.default.removeItem(at: untitledURL)
        try doc.encoded().write(to: renamedURL, options: .atomic)

        _ = await engine.pushDocument(at: renamedURL)
        let fileCount2 = await backend.fileCount()
        check(fileCount2 == 1, "rename updates in place without creating duplicate on Drive")
        let remoteMeta = await backend.fileMeta(entry1!.driveFileId!)
        check(remoteMeta?.name == "Roadmap.margins", "Drive filename updated in place")

        // Remote edit from Machine B pulled incrementally via changes.list
        var remoteDoc = doc
        remoteDoc.snapshot(html: "<h1>Roadmap</h1><p>From Mac B</p>", slug: "mac b", author: .you)
        _ = try await backend.updateRemote(fileID: entry1!.driveFileId!, doc: remoteDoc)

        _ = await engine.syncAll()
        let pulled = try MarginsDocument.decode(Data(contentsOf: renamedURL))
        check(pulled.html.contains("From Mac B"), "incremental pull updates local .margins file")
        let mdURL = dir.appendingPathComponent("Roadmap.md")
        let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        check(md.contains("From Mac B"), "pull regenerates local Markdown mirror")
    } catch {
        check(false, "sync engine lifecycle test threw \(error)")
    }

    // 2. V1 Conflict resolution (zero data loss) when remote moved ahead before push
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-sync-2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemorySyncBackend()
        let fixedDate = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01
        let engine = SyncEngine(
            backend: backend,
            documentsFolder: dir,
            indexURL: dir.appendingPathComponent("sync-index.json"),
            hostName: "MacBook-Pro.local",
            now: { fixedDate }
        )

        var doc = MarginsDocument()
        doc.snapshot(html: "<h1>Notes</h1><p>Base</p>", slug: "base", author: .you)
        let url = dir.appendingPathComponent("Notes.margins")
        try doc.encoded().write(to: url, options: .atomic)
        _ = await engine.syncAll()
        let driveID = await engine.currentIndex().entry(for: doc.id)!.driveFileId!

        // Machine B updates Drive first
        var macBDoc = doc
        macBDoc.snapshot(html: "<h1>Notes</h1><p>Mac B edit</p>", slug: "b", author: .you)
        _ = try await backend.updateRemote(fileID: driveID, doc: macBDoc)

        // Machine A edits locally offline and pushes
        var macADoc = doc
        macADoc.snapshot(html: "<h1>Notes</h1><p>Mac A edit</p>", slug: "a", author: .you)
        try macADoc.encoded().write(to: url, options: .atomic)

        let conflictStatus = await engine.pushDocument(at: url)
        check(conflictStatus == .conflict(count: 1), "divergent push detects conflict")
        let entry = await engine.currentIndex().entry(for: doc.id)
        check(entry?.state == .conflict, "entry marked conflict")
        check(entry?.conflictFilename == "Notes (Conflict on MacBook-Pro 2025-01-01).margins", "conflict copy named with host and date")
        let conflictURL = dir.appendingPathComponent(entry!.conflictFilename!)
        let conflictDoc = try MarginsDocument.decode(Data(contentsOf: conflictURL))
        let canonicalDoc = try MarginsDocument.decode(Data(contentsOf: url))
        check(conflictDoc.html.contains("Mac A edit"), "conflict copy preserves local edit")
        check(canonicalDoc.html.contains("Mac B edit"), "canonical file updated to remote version")
    } catch {
        check(false, "conflict resolution test threw \(error)")
    }

    // 3. Offline queue + retry, deduplication by doc.id, and cloudOnly on-demand download
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margins-sync-3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemorySyncBackend()
        var cloudDoc = MarginsDocument()
        cloudDoc.snapshot(html: "<h1>Remote Only</h1><p>In Drive</p>", slug: "remote", author: .you)
        _ = try await backend.seedRemote(doc: cloudDoc, name: "Remote Only.margins")

        let engine = SyncEngine(
            backend: backend,
            documentsFolder: dir,
            indexURL: dir.appendingPathComponent("sync-index.json"),
            hostName: "Mini"
        )

        // Lazy initial sync indexes remote doc as cloudOnly without downloading
        _ = await engine.syncAll(uploadExistingLocal: false, lazyDownload: true)
        let cloudEntry = await engine.currentIndex().entry(for: cloudDoc.id)
        check(cloudEntry?.state == .cloudOnly, "lazy sync marks remote doc as cloudOnly")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Remote Only.margins").path), "cloudOnly file not yet on disk")

        // On-demand download via ensureLocal
        let downloadedURL = try await engine.ensureLocal(docID: cloudDoc.id)
        check(FileManager.default.fileExists(atPath: downloadedURL.path), "ensureLocal downloads file on demand")
        let afterEntry = await engine.currentIndex().entry(for: cloudDoc.id)
        check(afterEntry?.state == .synced, "entry transitions to synced after on-demand download")

        // Offline write queues as pendingUpload, then flushes when back online
        await backend.setOffline(true)
        var localDoc = MarginsDocument()
        localDoc.snapshot(html: "<h1>Offline Draft</h1><p>Plane mode</p>", slug: "offline", author: .you)
        let offlineURL = dir.appendingPathComponent("Offline Draft.margins")
        try localDoc.encoded().write(to: offlineURL, options: .atomic)
        let offlineStatus = await engine.pushDocument(at: offlineURL)
        check(offlineStatus == .offline(pendingCount: 1), "offline push reports offline with 1 pending")

        await backend.setOffline(false)
        let onlineStatus = await engine.syncAll()
        if case .synced = onlineStatus { check(true, "queued offline document uploads once back online") } else { check(false, "expected synced after reconnect, got \(onlineStatus)") }
        let syncedOfflineEntry = await engine.currentIndex().entry(for: localDoc.id)
        check(syncedOfflineEntry?.state == .synced && syncedOfflineEntry?.driveFileId != nil, "offline doc now has driveFileId")
    } catch {
        check(false, "offline queue & cloudOnly test threw \(error)")
    }

    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexURL = dir.appendingPathComponent("sync-index.json")
        let backend = InMemorySyncBackend()
        let legacy = Data(#"{"html":"<h1>Legacy</h1>","intents":[],"versions":[],"nextStep":1,"extra":"keep"}"#.utf8)
        let localURL = dir.appendingPathComponent("Draft.margins")
        try legacy.write(to: localURL)

        // Simulate an older upload with the ID only in Drive metadata and the index.
        let id = UUID()
        let remote = try await backend.upload(data: legacy, name: localURL.lastPathComponent, docID: id,
                                              folderID: "drive-folder-1", existingFileID: nil)
        var index = SyncIndex(folderID: "drive-folder-1", startPageToken: "0")
        index.setEntry(SyncEntry(docID: id, driveFileId: remote.id, lastSyncedRevision: remote.headRevisionId,
                                 lastSyncedContentHash: SyncEngine.sha256Hex(legacy), filename: remote.name,
                                 title: "Legacy", state: .cloudOnly))
        index.setEntry(SyncEntry(docID: UUID(), filename: remote.name, title: "Legacy"))
        try index.save(to: indexURL)
        let recovering = SyncEngine(backend: backend, documentsFolder: dir, indexURL: indexURL)
        _ = await recovering.syncAll()
        let migrated = try Data(contentsOf: localURL)
        let fields = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        check(fields?["id"] as? String == id.uuidString && fields?["extra"] as? String == "keep",
              "legacy scan persists the existing Drive identity and preserves unknown fields")
        let uploaded = try await backend.download(fileID: remote.id)
        check(uploaded == migrated, "legacy upload sends the same identified bytes stored on disk")
        let recovered = await recovering.currentIndex()
        check(recovered.entries.count == 1 && recovered.pendingUploadCount == 0, "stale local ID is removed after migration")

        // A distinct legacy file with identical bytes must retain its own identity.
        let otherURL = dir.appendingPathComponent("Copy.margins")
        try legacy.write(to: otherURL)
        _ = await recovering.pushDocument(at: otherURL)
        let other = try MarginsDocument.decode(Data(contentsOf: otherURL))
        check(other.id != id, "autosave migrates a separate legacy file independently")
        let restarted = SyncEngine(backend: backend, documentsFolder: dir, indexURL: indexURL)
        _ = await restarted.syncAll()
        _ = await restarted.syncAll()
        let count = await backend.fileCount()
        let settled = await restarted.currentIndex()
        let localNames = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".margins") }
        check(count == 2 && settled.entries.count == 2 && settled.pendingUploadCount == 0 && localNames.count == 2,
              "repeated sync and restart create no local or Drive duplicates")
    } catch {
        check(false, "legacy local migration threw \(error)")
    }

    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Shared.margins")
        try Data(#"{"html":"","intents":[],"versions":[],"nextStep":1}"#.utf8).write(to: url)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask { try SyncDocument.load(at: url, index: SyncIndex()).document.id }
            }
            var ids = Set<UUID>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        let stored = try MarginsDocument.decode(Data(contentsOf: url))
        check(ids == [stored.id], "overlapping editor and sync reads adopt one persisted legacy identity")
    } catch {
        check(false, "concurrent legacy migration threw \(error)")
    }

    for lazy in [false, true] {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let backend = InMemorySyncBackend()
            let remoteID = UUID()
            let legacy = Data(#"{"html":"<h1>From Drive</h1>","versions":[],"intents":[],"nextStep":1}"#.utf8)
            let remote = try await backend.upload(data: legacy, name: "Old.margins", docID: remoteID,
                                                  folderID: "drive-folder-1", existingFileID: nil)
            let engine = SyncEngine(backend: backend, documentsFolder: dir, indexURL: dir.appendingPathComponent("index.json"))
            _ = await engine.syncAll(lazyDownload: lazy)
            let url = try await engine.ensureLocal(docID: remoteID)
            let data = try Data(contentsOf: url)
            let doc = try MarginsDocument.decode(data)
            check(doc.id == remoteID, "legacy Drive download persists its metadata ID (lazy=\(lazy))")
            _ = await engine.syncAll()
            let index = await engine.currentIndex()
            let count = await backend.fileCount()
            check(count == 1 && index.entries.count == 1 && index.pendingUploadCount == 0 &&
                  index.entry(for: remoteID)?.lastSyncedContentHash == SyncEngine.sha256Hex(data),
                  "downloaded legacy bytes stay settled on the next scan (lazy=\(lazy))")
            let metadata = await backend.fileMeta(remote.id)
            check(metadata?.headRevisionId == remote.headRevisionId, "a legacy download alone does not trigger a re-upload")
        } catch {
            check(false, "legacy Drive migration threw \(error)")
        }
    }

    syncSem.signal()
}
syncSem.wait()

// --- Copilot Cloud Agents (gh CLI) tests ---

actor MockCloudCommandRunner: CloudCommandRunner {
    struct Call: Sendable {
        var executable: URL
        var arguments: [String]
        var stdin: String?
        var cwd: URL?
        var environment: [String: String]? = nil
    }

    private let ghURL: URL?
    private let binaries: [String: URL]
    private var handlers: [@Sendable (Call, (@Sendable (String) -> Void)?) async throws -> ProcessResult]
    private var recordedCalls: [Call] = []

    init(
        ghURL: URL? = URL(fileURLWithPath: "/usr/local/bin/gh"),
        binaries: [String: URL] = [:],
        handlers: [@Sendable (Call, (@Sendable (String) -> Void)?) async throws -> ProcessResult] = []
    ) {
        self.ghURL = ghURL
        self.binaries = binaries
        self.handlers = handlers
    }

    nonisolated func locate(_ name: String) -> URL? {
        name == "gh" ? ghURL : binaries[name]
    }

    func calls() -> [Call] { recordedCalls }

    func run(
        _ executable: URL,
        arguments: [String],
        stdin: String?,
        cwd: URL?,
        environment: [String: String]?,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin, cwd: cwd, environment: environment)
        recordedCalls.append(call)
        guard !handlers.isEmpty else {
            throw CopilotCloudError.invalidResponse("Unexpected CLI call: \(arguments.joined(separator: " "))")
        }
        let handler = handlers.removeFirst()
        return try await handler(call, onLine)
    }
}

test("CloudTaskRef persistence round-trip and legacy document backward compatibility") {
    let checkedAt = Date(timeIntervalSince1970: 1_730_000_000)
    let ref = CloudTaskRef(
        repo: "vivekhaldar/margins",
        baseRef: "main",
        taskID: "task-123",
        htmlURL: "https://github.com/vivekhaldar/margins/tasks/task-123",
        sessionID: "sess-9",
        cloudState: "in_progress",
        pullRequestURL: "https://github.com/vivekhaldar/margins/pull/42",
        lastCheckedAt: checkedAt,
        createPullRequest: true
    )
    let intent = Intent(step: 1, text: "Audit sync engine", status: .working, provider: "Copilot Cloud", cloudTask: ref)
    let doc = MarginsDocument(html: "<h1>Notes</h1>", intents: [intent], versions: [], nextStep: 2)
    let encoded = try doc.encoded()
    let decoded = try MarginsDocument.decode(encoded)
    check(decoded.intents.count == 1, "round-trip preserves intent count")
    check(decoded.intents[0].cloudTask == ref, "round-trip preserves CloudTaskRef fields")

    // Legacy document JSON without `cloudTask` must decode cleanly with `cloudTask == nil`.
    let legacyJSON = """
    {
      "format": 2,
      "html": "<h1>Legacy</h1>",
      "intents": [{
        "id": "11111111-1111-1111-1111-111111111111",
        "kind": "instruction",
        "step": 1,
        "text": "Tighten prose",
        "createdAt": "2026-01-01T00:00:00Z",
        "status": "done",
        "summary": "Done",
        "notes": [],
        "refinements": [],
        "provider": "Claude"
      }],
      "versions": [],
      "nextStep": 2
    }
    """
    let legacyDoc = try MarginsDocument.decode(Data(legacyJSON.utf8))
    check(legacyDoc.intents.count == 1 && legacyDoc.intents[0].cloudTask == nil, "legacy intent decodes with cloudTask == nil")
}

test("CloudTask payload construction, excerpt packaging, and read-only guardrails") {
    let roReq = CloudTaskRequest(
        repo: "octo/repo",
        baseRef: "main",
        instruction: "Explain the sync conflict logic",
        excerpt: "Selected passage from Margins",
        createPullRequest: false,
        model: "claude-sonnet-4.5",
        customAgent: "reviewer"
    )
    let (roPrompt, roJSON) = try CopilotCloudClient.buildStartPayload(for: roReq)
    let roObj = try JSONSerialization.jsonObject(with: Data(roJSON.utf8)) as? [String: Any]
    check(roObj?["base_ref"] as? String == "main", "base_ref included")
    check(roObj?["create_pull_request"] as? Bool == false, "create_pull_request false")
    check(roObj?["model"] as? String == "claude-sonnet-4.5", "optional model included")
    check(roObj?["custom_agent"] as? String == "reviewer", "optional custom_agent included")
    check(roPrompt.contains("Selected passage from Margins"), "excerpt packaged into prompt")
    check(roPrompt.contains(CopilotCloudClient.readOnlyGuardrail), "read-only guardrail appended when createPullRequest is false")

    let prReq = CloudTaskRequest(
        repo: "octo/repo",
        baseRef: "develop",
        instruction: "Fix typo in README",
        createPullRequest: true
    )
    let (prPrompt, prJSON) = try CopilotCloudClient.buildStartPayload(for: prReq)
    let prObj = try JSONSerialization.jsonObject(with: Data(prJSON.utf8)) as? [String: Any]
    check(prObj?["create_pull_request"] as? Bool == true, "create_pull_request true")
    check(prObj?["model"] == nil && prObj?["custom_agent"] == nil, "omitted optional fields not serialized")
    check(!prPrompt.contains(CopilotCloudClient.readOnlyGuardrail), "read-only guardrail omitted when createPullRequest is true")
}

test("CloudTaskState mapping and AgentNotificationCoordinator outcomes") {
    final class CloudMockDelivery: AgentNotificationDelivery {
        var isAvailable = true
        var delivered: [AgentNotificationPayload] = []
        func requestAuthorization() {}
        func deliver(_ payload: AgentNotificationPayload) { delivered.append(payload) }
        func removeDelivered(forDocumentURL url: URL) {}
    }

    let cases: [(String, Intent.Status, Bool, Bool, Bool)] = [
        ("queued", .working, true, false, false),
        ("in_progress", .working, true, false, false),
        ("waiting_for_user", .working, false, true, false),
        ("idle", .working, false, true, false),
        ("completed", .done, false, false, true),
        ("failed", .failed, false, false, true),
        ("cancelled", .failed, false, false, true),
        ("timed_out", .failed, false, false, true),
    ]
    for (raw, expectedStatus, expectedPoll, expectedAttention, expectedTerminal) in cases {
        let state = CloudTaskState(rawState: raw)
        check(state.intentStatus == expectedStatus, "state \(raw) maps to intentStatus \(expectedStatus)")
        check(state.shouldPoll == expectedPoll, "state \(raw) shouldPoll == \(expectedPoll)")
        check(state.needsAttention == expectedAttention, "state \(raw) needsAttention == \(expectedAttention)")
        check(state.isTerminal == expectedTerminal, "state \(raw) isTerminal == \(expectedTerminal)")
    }

    check(CloudTaskState.queued.notificationOutcome(summary: "", detail: "") == nil, "queued emits no notification")
    check(CloudTaskState.inProgress.notificationOutcome(summary: "", detail: "") == nil, "in_progress emits no notification")

    let suite = "margins.cloud.notify.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let delivery = CloudMockDelivery()
    let coordinator = AgentNotificationCoordinator(delivery: delivery, defaults: defaults)
    let docURL = URL(fileURLWithPath: "/tmp/Spec.margins")

    if let attn = CloudTaskState.waitingForUser.notificationOutcome(summary: "", detail: "Confirm schema migration") {
        coordinator.notify(documentURL: docURL, step: 1, outcome: attn, isDocumentFocused: false)
    }
    if let done = CloudTaskState.completed.notificationOutcome(summary: "PR ready", detail: "Opened PR #12") {
        coordinator.notify(documentURL: docURL, step: 2, outcome: done, isDocumentFocused: false)
    }
    if let fail = CloudTaskState.timedOut.notificationOutcome(summary: "", detail: "", error: "Task timed out") {
        coordinator.notify(documentURL: docURL, step: 3, outcome: fail, isDocumentFocused: false)
    }
    check(delivery.delivered.count == 3, "attention, completion, and failure notifications delivered")
    check(delivery.delivered[0].title.contains("Approval needed"), "waiting_for_user uses attention notification")
    check(delivery.delivered[1].body.contains("Opened PR #12"), "completed notification carries detail")
    check(delivery.delivered[2].title.contains("Agent failed"), "timed_out uses failure notification")
}

test("CloudTaskFormatter escapes HTML and filters unsafe URLs") {
    let html = CloudTaskFormatter.insertionHTML(
        intentText: "Fallback",
        reply: "Line 1 <script>alert(1)</script>\nLine 2\n\nSecond para",
        log: nil,
        summary: "",
        pullRequestURL: "https://github.com/octo/repo/pull/7",
        htmlURL: "javascript:alert(1)"
    )
    check(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), "HTML tags are escaped")
    check(html.contains("<br>"), "single newline converts to <br>")
    check(html.contains("https://github.com/octo/repo/pull/7"), "https PR link preserved")
    check(!html.contains("javascript:"), "unsafe URL scheme rejected")
}

test("CloudTaskFormatter.extractSummary keeps the final answer and drops tool steps") {
    let log = """
      I'll start by exploring the repository structure.

    Bash: List files

        $ ls -la
        total 12

    View README.md

        # Project

    Thought

      ## Summary

      The parser lives in Sources/Parser.swift and converts Markdown into
      HTML using a two-pass approach.

      │ File         │ Purpose │
      │──────────────┼─────────│
      │ Parser.swift │ parse   │

      • Handles tables
      • Handles footnotes and a long item that wraps onto the
        next terminal line

    """
    let summary = CloudTaskFormatter.extractSummary(fromLog: log)
    check(summary.hasPrefix("## Summary"), "summary starts at the final answer")
    check(!summary.contains("ls -la") && !summary.contains("README") && !summary.contains("explor"), "tool steps and earlier chatter dropped")
    check(summary.contains("converts Markdown into HTML using"), "terminal hard-wraps are unwrapped")
    check(summary.contains("│ Parser.swift │ parse   │"), "table rows kept intact")
    check(summary.contains("• Handles footnotes and a long item that wraps onto the next terminal line"), "wrapped list item joined")

    let short = CloudTaskFormatter.extractSummary(fromLog: log, maxChars: 140)
    check(!short.contains("│"), "truncation never splits a table")
    check(short.hasSuffix("two-pass approach."), "truncation stops at a paragraph boundary")
    let tiny = CloudTaskFormatter.extractSummary(fromLog: "  " + String(repeating: "word ", count: 50), maxChars: 30)
    check(tiny.count <= 30 && tiny.hasSuffix("…") && !tiny.contains("wor…"), "oversized paragraph cut at a word boundary")

    let withFooter = "  Final answer here.\n\nFor detailed session logs, try:\n\n  gh agent-task view 'abc' --log\n"
    check(CloudTaskFormatter.extractSummary(fromLog: withFooter) == "Final answer here.", "gh footer is ignored")
    check(CloudTaskFormatter.extractSummary(fromLog: "  \n\n") == "", "empty log yields empty summary")

    let nestedBullets = """
          "subject": "tool json"
        }

      Intro paragraph before nested bullets.

      • Top-level item:
          • Nested item that wraps onto the
          next terminal line at indent 6
          • Another nested item with a
            hanging continuation at indent 8

      Closing paragraph.
    """
    let nestedSummary = CloudTaskFormatter.extractSummary(fromLog: nestedBullets)
    check(nestedSummary.hasPrefix("Intro paragraph before nested bullets."), "nested bullet continuations do not truncate earlier prose")
    check(nestedSummary.contains("• Nested item that wraps onto the next terminal line at indent 6"), "wrapped nested bullet joined")
    check(nestedSummary.contains("• Another nested item with a hanging continuation at indent 8"), "hanging nested bullet joined")
    check(nestedSummary.hasSuffix("Closing paragraph."), "closing paragraph preserved after nested bullets")
    check(!nestedSummary.contains("tool json"), "preceding indented JSON still dropped")
}

test("CloudLogStreamAccumulator buffers reconnect replay and CloudWatcherPolicy") {
    var fresh = CloudLogStreamAccumulator(existing: nil)
    check(fresh.append("a") == "a" && fresh.append("b") == "a\nb", "first stream publishes immediately")

    var replay = CloudLogStreamAccumulator(existing: "a\nb\nc")
    check(replay.append("a") == nil && replay.append("b") == nil, "replay of already-shown log is buffered")
    check(replay.append("c") == "a\nb\nc", "publishes once replay catches up")
    check(replay.append("d") == "a\nb\nc\nd", "then appends live lines without duplicates")

    check(!CloudWatcherPolicy.shouldStartWatcher(trigger: .focus, watcherRunning: true), "focus leaves a live stream alone")
    check(CloudWatcherPolicy.shouldStartWatcher(trigger: .focus, watcherRunning: false), "focus restarts a missing watcher")
    check(CloudWatcherPolicy.shouldStartWatcher(trigger: .wake, watcherRunning: true), "wake restarts possibly-wedged streams")
    check(!CloudWatcherPolicy.shouldStartWatcher(trigger: .open, watcherRunning: true), "open does not duplicate watchers")
}

test("CloudTaskLifecycle folds snapshots into intents and gates notifications") {
    let checked = Date(timeIntervalSince1970: 1_730_000_500)
    let ref = CloudTaskRef(repo: "octo/repo", baseRef: "main", taskID: "t1", htmlURL: "https://github.com/octo/repo/tasks/t1")
    var intent = Intent(step: 3, text: "Audit parser", provider: "Copilot Cloud", cloudTask: ref)
    var plain = Intent(step: 4, text: "Local")
    check(CloudTaskLifecycle.apply(CloudTaskSnapshot(taskID: "x", htmlURL: "", state: "completed"), to: &plain) == nil,
          "non-cloud intents are untouched")
    check(plain.status == .working, "non-cloud status unchanged")

    let running = CloudTaskLifecycle.apply(
        CloudTaskSnapshot(taskID: "t1", htmlURL: "", state: "in_progress", sessionID: "s1"), to: &intent, at: checked)
    check(running == CloudSnapshotTransition(previousState: .queued, newState: .inProgress), "queued → in_progress transition")
    check(running?.continuePolling == true, "in-progress keeps polling")
    check(intent.cloudTask?.sessionID == "s1" && intent.cloudTask?.lastCheckedAt == checked, "session id and check time recorded")
    check(intent.cloudTask?.htmlURL == ref.htmlURL, "empty snapshot URL keeps the known task URL")

    let done = CloudTaskLifecycle.apply(CloudTaskSnapshot(taskID: "t1", htmlURL: "", state: "completed"), to: &intent)
    check(done?.continuePolling == false && intent.status == .done, "completed stops polling and marks done")
    check(intent.cloudTask?.sessionID == "s1", "missing session id in snapshot keeps the previous one")
    CloudTaskLifecycle.applyOutputs(to: &intent, state: .completed, excerpt: "Final answer.", pullRequestURL: "https://github.com/octo/repo/pull/9")
    check(intent.reply == "Final answer." && intent.summary == "Completed with pull request.", "completion records answer and PR summary")
    check(intent.cloudTask?.pullRequestURL == "https://github.com/octo/repo/pull/9", "PR URL stored on the task ref")

    intent.status = .pending
    CloudTaskLifecycle.apply(CloudTaskSnapshot(taskID: "t1", htmlURL: "", state: "completed"), to: &intent)
    check(intent.status == .pending, "inserted (pending review) result is not reset by a later poll")

    var failed = Intent(step: 5, text: "Fail", cloudTask: ref)
    CloudTaskLifecycle.applyOutputs(to: &failed, state: .timedOut, excerpt: "", pullRequestURL: nil)
    check(failed.error == "Cloud task timed out.", "terminal failure without log gets a fallback error")
    failed.error = "Original"
    CloudTaskLifecycle.applyOutputs(to: &failed, state: .failed, excerpt: "log tail", pullRequestURL: nil)
    check(failed.error == "Original", "existing error is preserved")
    var waiting = Intent(step: 6, text: "Ask", cloudTask: ref)
    CloudTaskLifecycle.applyOutputs(to: &waiting, state: .waitingForUser, excerpt: "Which branch?", pullRequestURL: nil)
    check(waiting.reply == "Which branch?" && waiting.error == nil && waiting.summary.isEmpty, "attention state surfaces the question")

    check(CloudTaskLifecycle.shouldNotify(state: .completed, previousState: .inProgress, alreadyNotifiedAttention: false), "completion notifies")
    check(!CloudTaskLifecycle.shouldNotify(state: .completed, previousState: .completed, alreadyNotifiedAttention: false),
          "re-polling a finished task does not re-notify")
    check(CloudTaskLifecycle.shouldNotify(state: .idle, previousState: .idle, alreadyNotifiedAttention: false), "first attention notifies")
    check(!CloudTaskLifecycle.shouldNotify(state: .idle, previousState: .inProgress, alreadyNotifiedAttention: true), "attention notifies once")
    check(intent.cloudActivity == "Copilot Cloud · Completed" && plain.cloudActivity == nil, "cloud activity label for threads")
}

test("CloudInsertionPlan targets the right block and builds a tracked edit") {
    let ref = CloudTaskRef(repo: "octo/repo", baseRef: "main", taskID: "t1", htmlURL: "https://github.com/octo/repo/tasks/t1")
    var intent = Intent(step: 7, text: "Summarize", summary: "Cloud task completed.", provider: "Copilot Cloud", cloudTask: ref)
    intent.reply = "Answer <b>here</b>."
    let runID = UUID()
    let plan = CloudInsertionPlan.make(intent: intent, log: nil, focus: ["b2"], blockIDs: ["b1", "b2", "b3"], runID: runID)
    check(plan?.edit.op == .insertAfter && plan?.edit.blockId == "b2", "inserts after the selected block")
    check(plan?.edit.html.contains("Answer &lt;b&gt;here&lt;/b&gt;.") == true, "inserted HTML is escaped")
    check(plan?.run.id == runID && plan?.run.intentId == intent.id && plan?.run.step == 7, "run links the edit to the intent step")
    check(plan?.run.status == "pending" && plan?.run.provider == "Copilot Cloud" && plan?.run.model == "octo/repo", "run attribution")

    check(CloudInsertionPlan.targetBlockID(intent: intent, focus: [], blockIDs: ["b1", "b2"]) == "b2", "no selection → end of document")
    check(CloudInsertionPlan.targetBlockID(intent: intent, focus: ["gone"], blockIDs: ["b1"]) == "b1", "stale selection ignored")
    check(CloudInsertionPlan.targetBlockID(intent: intent, focus: [], blockIDs: []) == "^", "empty document inserts at start")
    var threaded = intent
    threaded.thread = UUID()
    threaded.anchor = "b1"
    threaded.focus = ["b1", "b2"]
    check(CloudInsertionPlan.targetBlockID(intent: threaded, focus: ["b3"], blockIDs: ["b1", "b2", "b3"]) == "b2",
          "thread result lands after the discussed passage, not the current selection")
    threaded.focus = ["deleted"]
    check(CloudInsertionPlan.targetBlockID(intent: threaded, focus: [], blockIDs: ["b0", "b1", "b9"]) == "b1",
          "thread falls back to its anchor block")
    check(CloudInsertionPlan.make(intent: Intent(step: 1, text: "local"), log: nil, focus: [], blockIDs: []) == nil,
          "non-cloud intents have no insertion plan")
    check(CloudInsertionPlan.status(afterChanges: 0) == .done && CloudInsertionPlan.status(afterChanges: 2) == .pending,
          "insertion leaves the intent pending review only when it changed the document")

    var directRef = ref
    directRef.paragraphBlockID = "b2"
    var directIntent = Intent(step: 8, text: "Expand this", status: .done, summary: "Cloud task completed.", provider: "Copilot Cloud", cloudTask: directRef)
    directIntent.reply = "Expanded content."
    let directPlan = CloudInsertionPlan.make(intent: directIntent, log: nil, focus: ["b3"], blockIDs: ["b1", "b2", "b3"])
    check(directPlan?.edit.op == .replace && directPlan?.edit.blockId == "b2",
          "direct paragraph prompt replaces its rough prompt block")
    let fallbackPlan = CloudInsertionPlan.make(intent: directIntent, log: nil, focus: [], blockIDs: ["b1", "b3"])
    check(fallbackPlan?.edit.op == .insertAfter && fallbackPlan?.edit.blockId == "b3",
          "deleted prompt block falls back to insertAfter at document end")

    var doneMain = intent
    doneMain.status = .done
    var doneThread = threaded
    doneThread.status = .done
    check(!CloudInsertionPlan.shouldAutoInsert(intent: doneMain), "main-composer cloud tasks stay manual insert")
    check(CloudInsertionPlan.shouldAutoInsert(intent: doneThread), "selection-thread cloud tasks auto-insert on completion")
    check(CloudInsertionPlan.shouldAutoInsert(intent: directIntent), "direct-prompt cloud tasks auto-insert on completion")
    directIntent.status = .pending
    check(!CloudInsertionPlan.shouldAutoInsert(intent: directIntent), "already-inserted pending tasks do not auto-insert again")
    directIntent.status = .reviewed
    check(!CloudInsertionPlan.shouldAutoInsert(intent: directIntent), "reviewed tasks do not auto-insert again")
}

let cloudSem = DispatchSemaphore(value: 0)
Task {
    // 1. Timeout / duplicate-launch recovery: never retry POST. List items omit `prompt`, so candidates
    //    created since the POST are fetched individually and matched on `sessions[].prompt`.
    do {
        struct SimulatedTimeout: Error {}
        let fixedNow = Date(timeIntervalSince1970: 1_730_000_000)
        let iso = ISO8601DateFormatter()
        let req = CloudTaskRequest(repo: "octo/repo", baseRef: "main", instruction: "Refactor parser", createPullRequest: false)
        let expectedPrompt = CopilotCloudClient.packagePrompt(for: req)
        func json(_ obj: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) }
        let listJSON = json(["tasks": [
            ["id": "task-other", "state": "queued", "creator": ["id": 7], "created_at": iso.string(from: fixedNow.addingTimeInterval(5))],
            ["id": "task-recovered", "state": "queued", "creator": ["id": 42], "created_at": iso.string(from: fixedNow.addingTimeInterval(3))],
            ["id": "task-sibling", "state": "queued", "creator": ["id": 42], "created_at": iso.string(from: fixedNow.addingTimeInterval(1))],
            ["id": "task-old", "state": "completed", "creator": ["id": 42], "created_at": "2024-10-27T05:45:00Z"],
        ]])
        // GitHub may reflow whitespace; the initial session's prompt can also be empty.
        let recoveredDetail = json(["id": "task-recovered", "state": "queued", "html_url": "https://github.com/octo/repo/tasks/task-recovered",
                                    "sessions": [["id": "sess-a", "prompt": expectedPrompt.replacingOccurrences(of: "\n\n", with: "\n \n")],
                                                 ["id": "sess-0", "prompt": ""]]])
        let runner = MockCloudCommandRunner(handlers: [
            { _, _ in throw SimulatedTimeout() },
            { call, _ in
                check(call.arguments == ["api", "agents/repos/octo/repo/tasks?per_page=20&sort=created_at&direction=desc"],
                      "queries newest-created tasks on ambiguous POST")
                return ProcessResult(status: 0, stdout: listJSON, stderr: "")
            },
            { call, _ in
                check(call.arguments == ["api", "user", "--jq", ".id"], "looks up viewer to filter other users' tasks")
                return ProcessResult(status: 0, stdout: "42\n", stderr: "")
            },
            { call, _ in
                check(call.arguments == ["api", "agents/repos/octo/repo/tasks/task-recovered"], "skips other creators and fetches newest candidate")
                return ProcessResult(status: 0, stdout: recoveredDetail, stderr: "")
            },
        ])
        let client = CopilotCloudClient(runner: runner, now: { fixedNow })
        let recovered = try await client.startTask(req)
        check(recovered.taskID == "task-recovered", "recovered existing task instead of retrying POST")
        check(recovered.sessionID == "sess-a" || recovered.sessionID == "sess-0", "recovered snapshot carries session")
        let calls = await runner.calls()
        check(calls.filter { $0.arguments.contains("POST") }.count == 1, "POST is invoked exactly once")
    } catch {
        check(false, "timeout recovery test threw \(error)")
    }

    // 1b. Recovery refuses to guess when several candidates exist and none exposes a matching prompt.
    do {
        let fixedNow = Date(timeIntervalSince1970: 1_730_000_000)
        let created = ISO8601DateFormatter().string(from: fixedNow)
        let listJSON = #"{"tasks":[{"id":"t1","state":"queued","created_at":"\#(created)"},{"id":"t2","state":"queued","created_at":"\#(created)"}]}"#
        let empty: (String) -> String = { #"{"id":"\#($0)","state":"queued","sessions":[{"id":"s","prompt":""}]}"# }
        let runner = MockCloudCommandRunner(handlers: [
            { _, _ in ProcessResult(status: 1, stdout: "", stderr: "HTTP 502") },
            { _, _ in ProcessResult(status: 0, stdout: listJSON, stderr: "") },
            { _, _ in ProcessResult(status: 1, stdout: "", stderr: "no user scope") },
            { _, _ in ProcessResult(status: 0, stdout: empty("t1"), stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: empty("t2"), stderr: "") },
        ])
        let client = CopilotCloudClient(runner: runner, now: { fixedNow })
        do {
            _ = try await client.startTask(CloudTaskRequest(repo: "octo/repo", baseRef: "main", instruction: "Hi"))
            check(false, "ambiguous recovery should not attach to an arbitrary task")
        } catch {
            check(error.localizedDescription.contains("HTTP 502"), "surfaces original POST failure when recovery is ambiguous")
        }
    }

    // 1c. A single fresh candidate whose prompt GitHub has not exposed yet is accepted.
    do {
        let fixedNow = Date(timeIntervalSince1970: 1_730_000_000)
        let created = ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(2))
        let runner = MockCloudCommandRunner(handlers: [
            { _, _ in ProcessResult(status: 0, stdout: "not json", stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: #"{"tasks":[{"id":"only","state":"queued","created_at":"\#(created)"}]}"#, stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: "42", stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: #"{"id":"only","state":"queued","sessions":[{"id":"s1","prompt":""}]}"#, stderr: "") },
        ])
        let client = CopilotCloudClient(runner: runner, now: { fixedNow })
        let task = try await client.startTask(CloudTaskRequest(repo: "octo/repo", baseRef: "main", instruction: "Hi"))
        check(task.taskID == "only" && task.sessionID == "s1", "single unverified candidate is recovered")
    } catch {
        check(false, "single-candidate recovery threw \(error)")
    }

    // 2. Polling newest session selection, session metadata, log fetch, live log stream, and repo resolution
    do {
        let taskJSON = """
        {
          "id": "task-77",
          "html_url": "https://github.com/octo/repo/tasks/task-77",
          "state": "in_progress",
          "sessions": [
            {"id": "sess-1", "created_at": "2026-10-01T10:00:00Z"},
            {"id": "sess-3", "created_at": "2026-10-01T10:05:00.500Z"},
            {"id": "sess-2", "created_at": "2026-10-01T10:02:00Z"}
          ]
        }
        """
        let metaJSON = #"{"state":"completed","completedAt":"2026-10-01T10:12:00Z","pullRequestUrl":"https://github.com/octo/repo/pull/99"}"#
        let repoJSON = #"{"nameWithOwner":"octo/repo","defaultBranchRef":{"name":"trunk"}}"#

        final class LineCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let streamed = LineCollector()

        let runner = MockCloudCommandRunner(handlers: [
            { _, _ in ProcessResult(status: 0, stdout: repoJSON, stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: taskJSON, stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: metaJSON, stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: "Final summary line\n", stderr: "") },
            { _, onLine in
                onLine?("step 1")
                onLine?("step 2")
                return ProcessResult(status: 0, stdout: "step 1\nstep 2\n", stderr: "")
            },
        ])
        let client = CopilotCloudClient(runner: runner)
        let repoInfo = try await client.resolveRepo(in: URL(fileURLWithPath: "/tmp"))
        check(repoInfo == CloudRepoInfo(repo: "octo/repo", defaultBranch: "trunk"), "resolveRepo parses owner/repo and default branch")

        let polled = try await client.fetchTask(repo: "octo/repo", id: "task-77")
        check(polled.sessionID == "sess-3", "fetchTask selects newest session by timestamp")

        let meta = try await client.fetchSessionMetadata(repo: "octo/repo", sessionID: "sess-3")
        check(meta.state == "completed" && meta.pullRequestURL == "https://github.com/octo/repo/pull/99" && meta.completedAt != nil, "fetchSessionMetadata parses state, completedAt, pullRequestUrl")

        let log = try await client.fetchSessionLog(repo: "octo/repo", sessionID: "sess-3")
        check(log.contains("Final summary line"), "fetchSessionLog returns log output")

        _ = try await client.streamSessionLog(repo: "octo/repo", sessionID: "sess-3") { streamed.append($0) }
        check(streamed.all == ["step 1", "step 2"], "streamSessionLog delivers live lines")
    } catch {
        check(false, "polling and log parsing test threw \(error)")
    }

    // 3. Error handling: missing gh, unauthenticated, non-zero exit, malformed JSON, invalid repo
    do {
        let missingRunner = MockCloudCommandRunner(ghURL: nil)
        let missingClient = CopilotCloudClient(runner: missingRunner)
        let missingAuth = await missingClient.checkAuth()
        check(missingAuth == .missingBinary, "missing gh reported by checkAuth")
        do {
            _ = try await missingClient.fetchTask(repo: "octo/repo", id: "t1")
            check(false, "missing gh should throw")
        } catch let err as CopilotCloudError {
            check(err == .ghNotFound, "missing gh throws ghNotFound")
        }

        let errRunner = MockCloudCommandRunner(handlers: [
            { _, _ in ProcessResult(status: 1, stdout: "", stderr: "You are not logged into any GitHub hosts.") },
            { _, _ in ProcessResult(status: 1, stdout: "", stderr: "HTTP 403 Forbidden") },
            { _, _ in ProcessResult(status: 0, stdout: "not json at all", stderr: "") },
        ])
        let errClient = CopilotCloudClient(runner: errRunner)
        let unauth = await errClient.checkAuth()
        if case .notAuthenticated(let msg) = unauth {
            check(msg.contains("not logged into"), "unauthenticated gh auth status captured")
        } else {
            check(false, "expected notAuthenticated")
        }

        do {
            _ = try await errClient.fetchTask(repo: "octo/repo", id: "t1")
            check(false, "non-zero exit should throw")
        } catch let err as CopilotCloudError {
            if case .commandFailed(_, let status, let detail) = err {
                check(status == 1 && detail.contains("403"), "commandFailed reports exit status and stderr")
            } else {
                check(false, "expected commandFailed")
            }
        }

        do {
            _ = try await errClient.fetchTask(repo: "octo/repo", id: "t1")
            check(false, "malformed JSON should throw")
        } catch let err as CopilotCloudError {
            if case .invalidResponse = err {
                check(true, "malformed JSON throws invalidResponse")
            } else {
                check(false, "expected invalidResponse")
            }
        }

        do {
            _ = try await errClient.fetchTask(repo: "bad repo!", id: "t1")
            check(false, "invalid repo should throw")
        } catch let err as CopilotCloudError {
            if case .invalidInput = err {
                check(true, "invalid repo throws invalidInput")
            } else {
                check(false, "expected invalidInput")
            }
        }
    } catch {
        check(false, "error handling test threw \(error)")
    }

    cloudSem.signal()
}
cloudSem.wait()

// --- Amp Cloud Agents (amp -ox) tests ---

typealias AmpHandler = @Sendable (MockCloudCommandRunner.Call, (@Sendable (String) -> Void)?) async throws -> ProcessResult

let ampBin = URL(fileURLWithPath: "/opt/amp/bin/amp")
let ampBinaries = ["amp": ampBin, "pass": URL(fileURLWithPath: "/usr/local/bin/pass"), "git": URL(fileURLWithPath: "/usr/bin/git")]
let ampSecret = "fake-amp-key-for-tests-0123456789"
let ampThreadA = "T-0f1e2d3c-4b5a-6978-8091-a2b3c4d5e6f7"
let ampThreadB = "T-99999999-aaaa-bbbb-cccc-dddddddddddd"
let ampInitLine = #"{"type":"system","subtype":"init","session_id":"\#(ampThreadA)","cwd":"/workspace","tools":["Read"]}"#
let ampAssistantLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking into it — café\nsecond line"},{"type":"tool_use","id":"tu1","name":"Grep","input":{}}],"stop_reason":"end_turn"},"session_id":"\#(ampThreadA)"}"#
let ampResultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"The answer.","session_id":"\#(ampThreadA)"}"#
let ampErrorLine = #"{"type":"result","subtype":"error_max_turns","is_error":true,"error":"Too many turns","session_id":"\#(ampThreadA)"}"#

let ampPass: AmpHandler = { _, _ in ProcessResult(status: 0, stdout: "\(ampSecret)\nlogin: me\n", stderr: "") }

/// Replays NDJSON through `LineBuffer` in awkward chunk sizes, like a real pipe.
func ampStream(_ lines: [String], status: Int32 = 0, chunk: Int = 7) -> AmpHandler {
    { _, onLine in
        let bytes = Array((lines.joined(separator: "\n") + "\n").utf8)
        var buffer = LineBuffer()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunk, bytes.count)
            buffer.append(Data(bytes[index..<end])).forEach { onLine?($0) }
            index = end
        }
        if let rest = buffer.finish() { onLine?(rest) }
        return ProcessResult(status: status, stdout: lines.joined(separator: "\n"), stderr: "")
    }
}

func ampClient(_ runner: MockCloudCommandRunner, env: [String: String] = [:]) -> AmpCloudClient {
    AmpCloudClient(runner: runner, credentials: AmpCredentialProvider(runner: runner, environment: env))
}

final class AmpEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

test("Amp backend model: legacy refs, cloud-only backend, states, attribution") {
    let legacyJSON = #"{"repo":"o/r","baseRef":"main","taskID":"t1","htmlURL":"","cloudState":"in_progress","createPullRequest":false}"#
    let legacy = try JSONDecoder().decode(CloudTaskRef.self, from: Data(legacyJSON.utf8))
    check(legacy.backend == nil && legacy.resolvedBackend == .copilot, "legacy cloud refs decode as Copilot")
    check(CloudWatcherPolicy.shouldWatch(legacy), "legacy Copilot task in progress is still watched")
    let copilotJSON = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
    check(!copilotJSON.contains("backend"), "refs without a backend stay byte-compatible with older builds")

    var ref = AmpCloudLifecycle.newRef(project: "o/r", paragraphBlockID: "b1")
    ref.cloudState = "in_progress"
    let decoded = try JSONDecoder().decode(CloudTaskRef.self, from: JSONEncoder().encode(ref))
    check(decoded == ref && decoded.resolvedBackend == .amp, "Amp refs round-trip with their backend")
    check(!CloudWatcherPolicy.shouldWatch(decoded), "Amp tasks are never polled or re-invoked by watchers")

    check(!ProviderKind.allCases.map(\.rawValue).contains { $0.lowercased().contains("amp") }, "Amp is not a local provider kind")
    check(!ProviderKind.allCases.map(\.title).contains { $0.contains("Amp") }, "Amp never appears in local provider settings")
    check(CloudBackend.isCloudProvider("Amp Cloud") && CloudBackend.isCloudProvider("Copilot Cloud"), "both cloud providers recognized")
    check(!CloudBackend.isCloudProvider("Claude (Claude Code)"), "local providers are not cloud")

    for state in [CloudTaskState.submitted, .disconnected] {
        check(CloudTaskState(rawState: state.rawState) == state, "\(state.rawState) round-trips")
        check(!state.shouldPoll && !state.needsAttention, "\(state.rawState) is never polled")
    }
    check(CloudTaskState.submitted.displayLabel == "Submitted" && CloudTaskState.submitted.intentStatus == .done, "submitted label/status")
    check(CloudTaskState.disconnected.displayLabel == "Outcome unknown" && CloudTaskState.disconnected.intentStatus == .failed,
          "disconnected label/status")

    var intent = Intent(step: 1, text: "Explain the sync engine", provider: "Amp Cloud", cloudTask: ref)
    AmpCloudLifecycle.apply(.completed(threadID: ampThreadA, result: "It syncs."), to: &intent)
    check(intent.cloudActivity == "Amp Cloud · Completed", "activity line names Amp Cloud")
    let plan = CloudInsertionPlan.make(intent: intent, log: nil, focus: [], blockIDs: ["b0", "b1"])
    check(plan?.run.provider == "Amp Cloud", "inserted runs are attributed to Amp Cloud")
    check(plan?.edit.html.contains("Amp Thread") == true && plan?.edit.html.contains("Copilot Cloud Task") == false,
          "insertion links back to the Amp thread")
    check(plan?.edit.html.contains("https://ampcode.com/threads/\(ampThreadA)") == true, "insertion carries the thread URL")
    check(plan?.edit.op == .replace && plan?.edit.blockId == "b1", "⌘↩ Amp prompts replace their paragraph")
    check(CloudInsertionPlan.provider == "Copilot Cloud", "Copilot attribution unchanged")
}

test("Amp remotes, thread URLs and project validation") {
    check(AmpCloudClient.parseGitHubRemote("git@github.com:vivekhaldar/margins.git\n") == "vivekhaldar/margins", "SSH remote")
    check(AmpCloudClient.parseGitHubRemote("ssh://git@github.com/vivekhaldar/margins") == "vivekhaldar/margins", "ssh:// remote")
    check(AmpCloudClient.parseGitHubRemote("https://github.com/vivekhaldar/margins.git") == "vivekhaldar/margins", "HTTPS .git remote")
    check(AmpCloudClient.parseGitHubRemote("https://github.com/vivekhaldar/margins/") == "vivekhaldar/margins", "HTTPS remote")
    check(AmpCloudClient.parseGitHubRemote("https://gitlab.com/o/r.git") == nil, "non-GitHub remotes rejected")
    check(AmpCloudClient.parseGitHubRemote("https://github.com/o/r/tree/main") == nil, "deep paths rejected")
    check(AmpCloudClient.parseGitHubRemote("git@github.com:o/r;rm -rf.git") == nil, "unsafe names rejected")
    check(AmpCloudClient.threadID(inText: "Started thread https://ampcode.com/threads/\(ampThreadA)\n") == ampThreadA, "thread URL parsed")
    check(AmpCloudClient.threadID(inText: "https://example.com/threads/\(ampThreadA)") == nil, "only ampcode.com thread URLs")
    check(AmpCloudClient.isValidThreadID(ampThreadA) && !AmpCloudClient.isValidThreadID("T-; rm"), "thread ID validation")
    check(AmpCloudClient.streamArguments(project: "o/r") == ["-ox", "--project", "o/r", "--stream-json", "--no-archive-after-execute"],
          "streamed launch command")
    check(AmpCloudClient.detachedArguments(project: "o/r") == ["-ox", "--project", "o/r"], "detached launch command")
    check(AmpCloudClient.continueArguments(threadID: ampThreadA) == ["threads", "continue", ampThreadA, "-ox", "--stream-json"],
          "follow-up command")
}

test("Amp NDJSON decoding and chunking: only result is terminal") {
    var buffer = LineBuffer()
    let payload = Array(([ampInitLine, ampAssistantLine, "not json", ""].joined(separator: "\n") + "\n" + ampResultLine).utf8)
    var lines: [String] = []
    for start in stride(from: 0, to: payload.count, by: 3) {
        lines += buffer.append(Data(payload[start..<min(start + 3, payload.count)]))
    }
    if let rest = buffer.finish() { lines.append(rest) }
    check(lines == [ampInitLine, ampAssistantLine, "not json", ampResultLine], "lines reassembled across chunks (incl. UTF-8)")

    let events = lines.map(AmpCloudClient.decodeEvent)
    check(events[0] == .initialized(threadID: ampThreadA), "system/init carries the thread")
    check(events[1] == .progress("Looking into it — café\n→ Grep"), "assistant text + tool use become progress")
    check(events[2] == .ignored, "non-JSON ignored")
    check(events[3] == .result("The answer."), "result decoded")
    check(AmpCloudClient.decodeEvent(#"{"type":"mystery","x":1}"#) == .ignored, "unknown event types ignored")
    check(AmpCloudClient.decodeEvent(#"{"type":"user","message":{"content":[]}}"#) == .ignored, "tool results ignored")
    check(AmpCloudClient.decodeEvent(ampErrorLine) == .error(message: "Too many turns", subtype: "error_max_turns"), "is_error result")
    check(AmpCloudClient.decodeEvent(#"{"type":"system","subtype":"error_during_execution","error":"Orb crashed"}"#)
          == .error(message: "Orb crashed", subtype: "error_during_execution"), "system error event decoded")
    check(AmpCloudClient.decodeEvent(#"{"type":"system","subtype":"error_max_turns","error":"Hit turn limit"}"#)
          == .error(message: "Hit turn limit", subtype: "error_max_turns"), "system max-turns error decoded")
    check(AmpCloudClient.decodeEvent(#"{"type":"system","subtype":"status","message":"ok"}"#) == .ignored, "non-error system subtype ignored")

    let packaged = AmpCloudClient.packagePrompt(instruction: "Fix the bug", excerpt: "Selected text")
    check(packaged.contains("Fix the bug") && packaged.contains("Selected text"), "Amp prompt includes instruction and excerpt")
    check(!packaged.contains("Read-only mode") && !packaged.contains(CopilotCloudClient.readOnlyGuardrail),
          "Amp prompt does not inject Copilot read-only guardrail")
    check(AmpCloudClient.packagePrompt(instruction: "Follow up", excerpt: nil) == "Follow up",
          "Amp follow-up prompt is not wrapped in read-only guardrail")

    let tracker = AmpStreamTracker()
    events.prefix(3).forEach(tracker.observe)
    check(tracker.snapshot().terminal == nil, "end_turn is not terminal")
    tracker.observe(events[3])
    check(tracker.snapshot().terminal == .completed(threadID: ampThreadA, result: "The answer."), "result is terminal")
}

test("Amp lifecycle: stopping, continuation and notifications") {
    var queued = Intent(step: 1, text: "q", provider: "Amp Cloud", cloudTask: AmpCloudLifecycle.newRef(project: "o/r"))
    check(AmpCloudLifecycle.markStopped(&queued) == .cancelled && queued.status == .failed, "never-launched turn is cancelled")
    var live = Intent(step: 2, text: "l", provider: "Amp Cloud", cloudTask: AmpCloudLifecycle.newRef(project: "o/r"))
    AmpCloudLifecycle.applyThread(ampThreadA, to: &live)
    check(AmpCloudLifecycle.markStopped(&live) == .disconnected, "live turn becomes outcome unknown")
    check(live.cloudTask?.taskID == ampThreadA && live.cloudTask?.htmlURL.hasSuffix(ampThreadA) == true, "thread handle preserved")
    check(AmpCloudLifecycle.markStopped(&live) == nil, "already-stopped turns are left alone")
    AmpCloudLifecycle.applyThread(ampThreadB, to: &live)
    check(live.cloudTask?.cloudState == "disconnected" && live.cloudTask?.taskID == ampThreadA, "late init never reopens a finished turn")
    var copilot = Intent(step: 3, text: "c", cloudTask: CloudTaskRef(repo: "o/r", baseRef: "main", taskID: "t", htmlURL: "", cloudState: "in_progress"))
    check(AmpCloudLifecycle.markStopped(&copilot) == nil && copilot.cloudTask?.cloudState == "in_progress", "Copilot tasks untouched")

    let threadA = UUID(), threadB = UUID()
    func amp(_ thread: UUID?, _ id: String) -> Intent {
        var ref = AmpCloudLifecycle.newRef(project: "o/r")
        ref.taskID = id
        var intent = Intent(step: 1, text: "x", provider: "Amp Cloud", cloudTask: ref)
        intent.thread = thread
        return intent
    }
    var copilotInA = copilot
    copilotInA.thread = threadA
    let intents = [amp(threadA, ampThreadA), amp(threadB, ampThreadB), amp(threadA, ""), copilotInA]
    check(AmpCloudLifecycle.continuationThreadID(in: intents, thread: threadA) == ampThreadA, "thread A continues its own Amp thread")
    check(AmpCloudLifecycle.continuationThreadID(in: intents, thread: threadB) == ampThreadB, "thread B continues its own Amp thread")
    check(AmpCloudLifecycle.continuationThreadID(in: intents, thread: UUID()) == nil, "new Margins threads start new Amp threads")
    check(AmpCloudLifecycle.continuationThreadID(in: intents, thread: nil) == nil, "composer prompts start new threads")

    var done = amp(threadA, ampThreadA)
    done.status = .reviewed
    AmpCloudLifecycle.apply(.failed(threadID: ampThreadA, message: "boom"), to: &done)
    check(done.status == .reviewed && done.cloudTask?.cloudState == "failed", "review status is never overwritten")
    check(AmpCloudLifecycle.notificationOutcome(for: done, state: .submitted) == nil, "submitted runs do not notify")
    let log = (0..<450).reduce(nil as String?) { AmpCloudLifecycle.appendingProgress("line \($1)", to: $0) }
    check(log?.hasPrefix("line 50\n") == true && log?.hasSuffix("line 449") == true, "progress log keeps the latest lines")
    check(AmpCloudLifecycle.notificationOutcome(for: done, state: .failed) == .failed(error: "boom"), "failures notify")
}

let ampSem = DispatchSemaphore(value: 0)
Task {
    // Streamed run: chunked NDJSON → completed; secret only in the child environment.
    do {
        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [
            ampPass, ampStream([ampInitLine, ampAssistantLine, #"{"type":"telemetry"}"#, ampResultLine])
        ])
        let events = AmpEventLog()
        let outcome = try await ampClient(runner).streamTurn(project: "o/r", prompt: "Summarize sync") { event in
            switch event {
            case .initialized(let id): events.add("init:\(id)")
            case .progress(let text): events.add("progress:\(text)")
            case .result(let text): events.add("result:\(text)")
            case .error(let message, _): events.add("error:\(message)")
            case .ignored: events.add("ignored")
            }
        }
        check(outcome == .completed(threadID: ampThreadA, result: "The answer."), "streamed turn completes on result")
        check(events.all.first == "init:\(ampThreadA)" && events.all.last == "result:The answer.", "init first, result last")
        check(!events.all.contains("ignored"), "ignored events are not forwarded")
        let calls = await runner.calls()
        check(calls.count == 2 && calls[0].arguments == ["show", "AMPCODE/API_KEY"], "key read once from pass")
        let launch = calls[1]
        check(launch.executable == ampBin && launch.arguments == AmpCloudClient.streamArguments(project: "o/r"), "launch argv")
        check(launch.stdin == "Summarize sync", "prompt sent on stdin")
        check(launch.environment?["AMP_API_KEY"] == ampSecret, "key passed via AMP_API_KEY")
        check(launch.environment?["PATH"]?.isEmpty == false, "child environment keeps PATH")
        check(!launch.arguments.joined().contains(ampSecret) && launch.stdin?.contains(ampSecret) == false, "key never in argv/stdin")
    } catch {
        check(false, "Amp streamed turn threw \(error)")
    }

    // is_error result and system error events → failed (with subtype); a result is terminal regardless of exit status.
    do {
        let systemErrLine = #"{"type":"system","subtype":"error_during_execution","error":"Orb crashed"}"#
        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [
            ampPass,
            ampStream([ampInitLine, ampErrorLine], status: 1),
            ampStream([ampInitLine, systemErrLine], status: 1),
            ampStream([ampInitLine, ampResultLine], status: 2)
        ])
        let client = ampClient(runner)
        let failed = try await client.streamTurn(project: "o/r", prompt: "p") { _ in }
        check(failed == .failed(threadID: ampThreadA, message: "error_max_turns: Too many turns"), "is_error result fails")
        let sysFailed = try await client.streamTurn(project: "o/r", prompt: "p") { _ in }
        check(sysFailed == .failed(threadID: ampThreadA, message: "error_during_execution: Orb crashed"),
              "system error event without result fails instead of disconnecting")
        let ok = try await client.streamTurn(project: "o/r", prompt: "p") { _ in }
        check(ok == .completed(threadID: ampThreadA, result: "The answer."), "result wins over exit status")
        let awaited1 = await runner.calls().count == 4
        check(awaited1, "cached key: pass called once for three turns")
    } catch {
        check(false, "Amp terminal semantics threw \(error)")
    }

    // Interrupted stream → disconnected, handle kept, nothing relaunched.
    do {
        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [ampPass, ampStream([ampInitLine, ampAssistantLine], status: 143)])
        let outcome = try await ampClient(runner).streamTurn(project: "o/r", prompt: "p") { _ in }
        guard case .disconnected(let id, _) = outcome else { check(false, "expected disconnected, got \(outcome)"); return }
        check(id == ampThreadA, "disconnected outcome keeps the thread")
        var intent = Intent(step: 1, text: "p", provider: "Amp Cloud", cloudTask: AmpCloudLifecycle.newRef(project: "o/r"))
        check(AmpCloudLifecycle.apply(outcome, to: &intent) == .disconnected, "intent marked outcome unknown")
        check(intent.cloudTask?.htmlURL == "https://ampcode.com/threads/\(ampThreadA)", "thread link persisted")
        check(intent.error?.hasPrefix("Outcome unknown") == true, "explains the unknown outcome")
        check(!CloudWatcherPolicy.shouldWatch(intent.cloudTask!), "disconnected Amp runs are not re-watched")
        let awaited2 = await runner.calls().count == 2
        check(awaited2, "no retry after an interrupted stream")
    } catch {
        check(false, "Amp interrupted stream threw \(error)")
    }

    // Detached dispatch: exactly one amp call; submitted or unknown, never retried.
    do {
        let url = "https://ampcode.com/threads/\(ampThreadB)"
        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [
            ampPass,
            { _, _ in ProcessResult(status: 0, stdout: "Thread started: \(url)\n", stderr: "") },
            { _, _ in ProcessResult(status: 0, stdout: "ok\n", stderr: "") },
            { _, _ in ProcessResult(status: 1, stdout: "", stderr: "auth failed for key \(ampSecret)") }
        ])
        let client = ampClient(runner)
        let submitted = try await client.dispatchDetached(project: "o/r", prompt: "Long task")
        check(submitted == .submitted(threadID: ampThreadB), "detached launch returns the thread")
        let calls = await runner.calls()
        check(calls.count == 2 && calls[1].arguments == AmpCloudClient.detachedArguments(project: "o/r"), "single detached amp call")
        let unknown = try await client.dispatchDetached(project: "o/r", prompt: "Long task")
        guard case .disconnected(nil, _) = unknown else { check(false, "unparseable detached output should be unknown"); return }
        let awaited3 = await runner.calls().count == 3
        check(awaited3, "unparseable detached output is not retried")
        let failed = try await client.dispatchDetached(project: "o/r", prompt: "Long task")
        guard case .failed(_, let message) = failed else { check(false, "expected failure"); return }
        check(!message.contains(ampSecret) && message.contains("[REDACTED]"), "errors are redacted")
        var intent = Intent(step: 1, text: "p", provider: "Amp Cloud", cloudTask: AmpCloudLifecycle.newRef(project: "o/r"))
        check(AmpCloudLifecycle.apply(submitted, to: &intent) == .submitted && intent.status == .done, "submitted intent")
        let saved = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        check(!saved.contains(ampSecret), "key never persisted in the document")
    } catch {
        check(false, "Amp detached dispatch threw \(error)")
    }

    // Credentials: env fallback, timeout, invalidate, missing binary; key redacted from streamed text.
    do {
        let slowPass: AmpHandler = { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ProcessResult(status: 0, stdout: ampSecret, stderr: "")
        }
        let started = Date()
        let timed = AmpCredentialProvider(runner: MockCloudCommandRunner(binaries: ampBinaries, handlers: [slowPass]),
                                          environment: [:], timeout: 0.2)
        do {
            _ = try await timed.apiKey()
            check(false, "stuck pass should time out")
        } catch let error as AmpCredentialError {
            check(error == .timedOut, "pass timeout reported")
            check(Date().timeIntervalSince(started) < 2, "timeout does not wait for pass to exit")
        }
        let fallback = AmpCredentialProvider(
            runner: MockCloudCommandRunner(binaries: ampBinaries, handlers: [{ _, _ in ProcessResult(status: 2, stdout: "", stderr: "gpg: decryption failed") }]),
            environment: ["AMP_API_KEY": " env-key \n"])
        let awaited4 = try await fallback.apiKey() == "env-key"
        check(awaited4, "AMP_API_KEY fallback")
        let noPass = AmpCredentialProvider(runner: MockCloudCommandRunner(binaries: [:]), environment: [:])
        do { _ = try await noPass.apiKey(); check(false, "no key source should throw") } catch { check(error is AmpCredentialError, "unavailable key") }

        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [ampPass, ampPass])
        let provider = AmpCredentialProvider(runner: runner, environment: [:])
        _ = try await provider.apiKey()
        _ = try await provider.apiKey()
        let awaited5 = await runner.calls().count == 1
        check(awaited5, "key cached in memory")
        await provider.invalidate()
        _ = try await provider.apiKey()
        let awaited6 = await runner.calls().count == 2
        check(awaited6, "invalidate re-reads pass")

        let missing = MockCloudCommandRunner(binaries: [:])
        let awaited7 = await ampClient(missing).preflight() == .missingBinary
        check(awaited7, "preflight reports missing amp")
        do { _ = try await ampClient(missing).streamTurn(project: "o/r", prompt: "p") { _ in }; check(false, "missing amp should throw") }
        catch { check(error as? AmpCloudError == .missingBinary, "missing amp throws") }

        let leaky = #"{"type":"result","subtype":"success","is_error":false,"result":"key=\#(ampSecret)"}"#
        let leakRunner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [ampPass, ampStream([ampInitLine, leaky])])
        let leakEvents = AmpEventLog()
        let leaked = try await ampClient(leakRunner).streamTurn(project: "o/r", prompt: "p") { event in
            if case .result(let text) = event { leakEvents.add(text) }
        }
        check(leaked == .completed(threadID: ampThreadA, result: "key=[REDACTED]") && leakEvents.all == ["key=[REDACTED]"],
              "key redacted from results and events")
    } catch {
        check(false, "Amp credential tests threw \(error)")
    }

    // Thread isolation: per-key serialization, other keys run concurrently; follow-ups continue their own thread.
    do {
        let serializer = AmpTurnSerializer()
        let order = AmpEventLog()
        let keyA = AmpTurnSerializer.key(thread: UUID(), intentID: UUID())
        let keyB = AmpTurnSerializer.key(thread: nil, intentID: UUID())
        async let first: Void = serializer.run(key: keyA) {
            order.add("a1-start")
            try? await Task.sleep(nanoseconds: 200_000_000)
            order.add("a1-end")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second: Void = serializer.run(key: keyA) { order.add("a2") }
        async let other: Void = serializer.run(key: keyB) { order.add("b") }
        _ = await (first, second, other)
        let log = order.all
        check(log.firstIndex(of: "a2")! > log.firstIndex(of: "a1-end")!, "follow-ups wait for the previous turn")
        check(log.firstIndex(of: "b")! < log.firstIndex(of: "a1-end")!, "other threads are not blocked")

        let runner = MockCloudCommandRunner(binaries: ampBinaries, handlers: [ampPass, ampStream([ampResultLine])])
        let outcome = try await ampClient(runner).continueTurn(threadID: ampThreadB, prompt: "And then?") { _ in }
        check(outcome == .completed(threadID: nil, result: "The answer."), "follow-up completes")
        let awaited8 = await runner.calls().last?.arguments == AmpCloudClient.continueArguments(threadID: ampThreadB)
        check(awaited8, "continues the saved thread")
        do { _ = try await ampClient(runner).continueTurn(threadID: "T-x; rm", prompt: "p") { _ in }; check(false, "bad id") }
        catch { check(error as? AmpCloudError != nil, "invalid thread IDs rejected before launch") }
    } catch {
        check(false, "Amp serialization tests threw \(error)")
    }

    // Opt-in live two-turn smoke test (needs `amp` and a key): MARGINS_TEST_AMP_LIVE=1 [MARGINS_TEST_AMP_PROJECT=owner/repo]
    let liveEnv = ProcessInfo.processInfo.environment
    if liveEnv["MARGINS_TEST_AMP_LIVE"] == "1" {
        let client = AmpCloudClient()
        let status = await client.preflight()
        check(status.isReady, "live: amp preflight \(status)")
        do {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            var project = liveEnv["MARGINS_TEST_AMP_PROJECT"] ?? ""
            if project.isEmpty { project = try await client.resolveProject(in: cwd) }
            let turn1 = try await client.streamTurn(
                project: project,
                prompt: "Remember the marker orch-718 for our next message. Reply with exactly: noted",
                cwd: cwd
            ) { _ in }
            guard case .completed(let id1, let text1) = turn1, let threadID = id1 else {
                check(false, "live: turn 1 expected completion with thread ID, got \(turn1)"); return
            }
            check(AmpCloudClient.isValidThreadID(threadID) && !text1.isEmpty, "live: turn 1 completes with valid thread ID")
            let turn2 = try await client.continueTurn(
                threadID: threadID,
                prompt: "What marker did I ask you to remember? Reply with just the marker.",
                cwd: cwd
            ) { _ in }
            guard case .completed(let id2, let text2) = turn2 else {
                check(false, "live: turn 2 expected completion, got \(turn2)"); return
            }
            check((id2 == nil || id2 == threadID) && text2.contains("orch-718"), "live: turn 2 continues same thread and recalls marker")
        } catch {
            check(false, "live Amp smoke test threw \(error)")
        }
    }

    ampSem.signal()
}
ampSem.wait()

print(failures == 0 ? "✓ \(passes) checks passed" : "\(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
