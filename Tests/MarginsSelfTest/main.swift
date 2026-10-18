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

print(failures == 0 ? "✓ \(passes) checks passed" : "\(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
