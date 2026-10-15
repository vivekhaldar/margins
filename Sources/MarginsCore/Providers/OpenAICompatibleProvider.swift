import Foundation
import Security

/// Any server speaking the OpenAI Chat Completions API: OpenAI, OpenRouter, Azure-compatible
/// gateways, Ollama, LM Studio, vLLM…
public final class OpenAICompatibleProvider: ModelProvider {
    public let kind: ProviderKind = .openAICompatible
    public let displayName: String
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(displayName: String, baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private func req(_ path: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        r.timeoutInterval = 300
        return r
    }

    public func availableModels() async throws -> [ModelInfo] {
        let (data, resp) = try await session.data(for: req("models"))
        try check(resp, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = obj?["data"] as? [[String: Any]] ?? []
        return list.compactMap { ($0["id"] as? String).map { ModelInfo(id: $0) } }.sorted { $0.id < $1.id }
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        guard let model = request.model, !model.isEmpty else {
            throw ProviderError.notConfigured("Choose a model for \(displayName).")
        }
        var r = req("chat/completions")
        r.httpMethod = "POST"
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": request.system],
                         ["role": "user", "content": request.prompt]],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "edit_plan", "strict": true, "schema": EditPlanSchema.object]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        try check(resp, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = obj?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ProviderError.protocolError("Unexpected response: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return content
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw ProviderError.protocolError("\(displayName) HTTP \(h.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
    }
}

/// API keys live in the login Keychain, never in preferences or documents.
public enum Keychain {
    static let service = "com.vivekhaldar.margins"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
