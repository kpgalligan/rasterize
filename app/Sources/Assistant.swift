import AppKit
import Security

/// Keychain storage for the Anthropic API key (generic password). The
/// ANTHROPIC_API_KEY environment variable, when set, wins over this.
enum APIKeyStore {
    private static let service = "com.kgalligan.Rasterize"
    private static let account = "AnthropicAPIKey"

    static func resolve() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            !env.isEmpty
        {
            return env
        }
        return load()
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

struct OpenError: Error {
    let message: String
}

/// One conversation with the core's built-in agent loop (rz_assistant_*).
/// Events arrive on the main queue through `onEvent`. Tool calls execute
/// through AgentServer's dispatcher exactly like MCP tool calls.
///
/// Lifecycle: the session retains itself while the Rust side may still
/// call back (the context pointer passed to rz_assistant_new); `close()`
/// frees the Rust handle on a background queue — never on main, because
/// freeing joins a worker that may be waiting on the main thread to run
/// a tool — and drops that self-retain afterwards.
final class AssistantSession {
    private var handle: OpaquePointer?
    private var selfRef: UnsafeMutableRawPointer?

    /// Parsed event objects ({"type": ...}), delivered on the main queue.
    var onEvent: (([String: Any]) -> Void)?

    private init() {}

    static func open(apiKey: String, model: String, system: String)
        -> Result<AssistantSession, OpenError>
    {
        let session = AssistantSession()
        let catalog: String
        do {
            catalog = try AgentServer.shared.catalogJSON()
        } catch {
            return .failure(OpenError(message: "Could not build the tool catalog: \(error.localizedDescription)"))
        }
        var config: [String: Any] = [
            "api_key": apiKey, "model": model, "system": system,
        ]
        if let base = ProcessInfo.processInfo.environment["RZ_ASSISTANT_BASE_URL"],
            !base.isEmpty
        {
            config["api_base"] = base
        }
        guard let configData = try? JSONSerialization.data(withJSONObject: config),
            let configJSON = String(data: configData, encoding: .utf8)
        else {
            return .failure(OpenError(message: "Could not encode the assistant configuration."))
        }

        let ref = Unmanaged.passRetained(session).toOpaque()
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle = configJSON.withCString { configC in
            catalog.withCString { toolsC in
                rz_assistant_new(
                    configC, toolsC,
                    assistantToolTrampoline, nil,
                    assistantEventTrampoline, ref,
                    &err)
            }
        }
        guard let handle = handle else {
            Unmanaged<AssistantSession>.fromOpaque(ref).release()
            let message: String
            if let err = err {
                message = String(cString: err)
                rz_string_free(err)
            } else {
                message = "Could not start the assistant."
            }
            return .failure(OpenError(message: message))
        }
        session.handle = handle
        session.selfRef = ref
        return .success(session)
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let handle = handle else { return false }
        return text.withCString { rz_assistant_send(handle, $0) }
    }

    var isBusy: Bool {
        guard let handle = handle else { return false }
        return rz_assistant_is_busy(handle)
    }

    func cancel() {
        guard let handle = handle else { return }
        rz_assistant_cancel(handle)
    }

    /// Idempotent. After the background free completes, no further events
    /// arrive and the self-retain is dropped.
    func close() {
        guard let handle = handle, let ref = selfRef else { return }
        self.handle = nil
        self.selfRef = nil
        rz_assistant_cancel(handle)
        DispatchQueue.global(qos: .utility).async {
            rz_assistant_free(handle)
            Unmanaged<AssistantSession>.fromOpaque(ref).release()
        }
    }

    fileprivate func dispatchEvent(_ json: String) {
        guard
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                as? [String: Any]
        else { return }
        onEvent?(object)
    }
}

/// Tool executor for assistant sessions: identical contract to the MCP
/// server's handler — hop to main, run through the shared dispatcher.
private func assistantToolTrampoline(
    _ context: UnsafeMutableRawPointer?,
    _ toolName: UnsafePointer<CChar>?,
    _ argumentsJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let toolName = toolName, let argumentsJSON = argumentsJSON else { return nil }
    let name = String(cString: toolName)
    let arguments = String(cString: argumentsJSON)
    let run = { AgentServer.shared.execute(tool: name, argumentsJSON: arguments) }
    let result = Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    return result.withCString { rz_agent_string_create($0) }
}

/// Event callback: copies the JSON and reposts to the main queue. The
/// async closure retains the session, so it stays alive for delivery
/// even if close() races this call.
private func assistantEventTrampoline(
    _ context: UnsafeMutableRawPointer?,
    _ eventJSON: UnsafePointer<CChar>?
) {
    guard let context = context, let eventJSON = eventJSON else { return }
    let session = Unmanaged<AssistantSession>.fromOpaque(context).takeUnretainedValue()
    let json = String(cString: eventJSON)
    DispatchQueue.main.async {
        session.dispatchEvent(json)
    }
}
