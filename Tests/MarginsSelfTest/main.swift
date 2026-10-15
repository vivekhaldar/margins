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
    check((o["required"] as? [String])?.count == 4, "required fields")
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

let sem = DispatchSemaphore(value: 0)
Task {
    let r = try! await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: "hello")
    check(r.stdout == "hello" && r.status == 0, "process runner stdin/stdout")
    sem.signal()
}
sem.wait()

print(failures == 0 ? "✓ \(passes) checks passed" : "\(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
