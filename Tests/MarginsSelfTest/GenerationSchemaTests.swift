import Foundation
@testable import MarginsCore

func runGenerationSchemaTests() {
    test("generation schema defaults and text opt-out") {
        let edit = GenerationRequest(system: "system", prompt: "prompt")
        check(edit.outputSchema == EditPlanSchema.json, "existing edit requests default to strict edit plans")
        let summary = GenerationRequest(system: "system", prompt: "prompt", outputSchema: nil)
        check(summary.outputSchema == nil && summary.combined == edit.combined, "plain HTML requests retain prompt channels")
        check(ClaudeCodeProvider.schemaArguments(edit.outputSchema) == ["--json-schema", EditPlanSchema.json],
              "Claude edit requests remain constrained")
        check(ClaudeCodeProvider.schemaArguments(summary.outputSchema).isEmpty, "Claude summary omits schema flag")
        let custom = #"{"type":"object","properties":{"answer":{"type":"string"}}}"#
        check(ClaudeCodeProvider.schemaArguments(custom) == ["--json-schema", custom], "Claude uses requested schema")
        let html = "<h1>Summary</h1><p>Direct HTML.</p>"
        let result = #"{"type":"result","result":"<h1>Summary</h1><p>Direct HTML.</p>","is_error":false}"#
        check(try ClaudeCodeProvider.extract(stdout: result, status: 0, stderr: "") == html,
              "Claude returns unconstrained HTML directly")
        let codex = #"{"type":"item.completed","item":{"type":"agent_message","text":"<h1>Summary</h1><p>Direct HTML.</p>"}}"#
        check(CodexExecProvider.lastAgentMessage(jsonl: codex) == html, "Codex returns direct HTML from JSONL transport")
    }
    test("Codex writes schemas only when constrained") {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".margins-schema-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.schema.json")
        check(try CodexExecProvider.schemaArguments(nil, at: url).isEmpty, "unconstrained Codex requests omit schema flag")
        check(!FileManager.default.fileExists(atPath: url.path), "unconstrained Codex does not write schema file")
        let edit = GenerationRequest(system: "s", prompt: "p")
        check(try CodexExecProvider.schemaArguments(edit.outputSchema, at: url) == ["--output-schema", url.path],
              "default edit plan schema argument retained")
        check(try String(contentsOf: url, encoding: .utf8) == EditPlanSchema.json, "default schema file contents retained")
        let custom = #"{"type":"object","required":["answer"]}"#
        _ = try CodexExecProvider.schemaArguments(custom, at: url)
        check(try String(contentsOf: url, encoding: .utf8) == custom, "Codex uses supplied custom schema")
    }
    test("OpenAI request format follows requested schema") {
        let edit = GenerationRequest(system: "system", prompt: "prompt", model: "model")
        let body = try OpenAICompatibleProvider.requestBody(edit, model: "model")
        let format = body["response_format"] as? [String: Any]
        let jsonSchema = format?["json_schema"] as? [String: Any]
        check(format?["type"] as? String == "json_schema" && jsonSchema?["strict"] as? Bool == true,
              "OpenAI edit plans retain strict structured output")
        check(jsonSchema?["name"] as? String == "edit_plan", "default schema name preserved")
        let schema = jsonSchema?["schema"] as? [String: Any]
        check(schema?["required"] as? [String] == ["slug", "summary", "notes", "edits", "reply"],
              "OpenAI default parses actual edit plan schema")
        let summary = GenerationRequest(system: "system", prompt: "prompt", outputSchema: nil)
        let plain = try OpenAICompatibleProvider.requestBody(summary, model: "model")
        check(plain["response_format"] == nil, "OpenAI summary requests omit response format")
        check(plain["model"] as? String == "model" && (plain["messages"] as? [[String: String]])?.count == 2,
              "unconstrained requests preserve model and message channels")
        check((try? JSONSerialization.data(withJSONObject: plain)) != nil, "unconstrained body remains valid JSON")
        let custom = GenerationRequest(system: "", prompt: "", outputSchema: #"{"type":"object","required":["answer"]}"#)
        let customBody = try OpenAICompatibleProvider.requestBody(custom, model: "model")
        let customSchema = ((customBody["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        check(customSchema?["required"] as? [String] == ["answer"], "OpenAI honors custom schema instead of hardcoded edit plan")
        let malformed = GenerationRequest(system: "", prompt: "", outputSchema: "not JSON")
        let array = GenerationRequest(system: "", prompt: "", outputSchema: "[]")
        check((try? OpenAICompatibleProvider.requestBody(malformed, model: "model")) == nil, "invalid schema JSON rejected")
        check((try? OpenAICompatibleProvider.requestBody(array, model: "model")) == nil, "nonobject schema rejected")
    }
}
