import Foundation

// MARK: - Config

/// OpenAI-compatible endpoint config. Stored in UserDefaults. Structured so that
/// shipping later only requires pointing `baseURL` at your own backend proxy.
struct AIConfig: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var model: String = "gpt-audio-mini"        // audio-in explain model
    var scriptModel: String = "gpt-4o-mini"     // text model writing generation scripts
    var ttsModel: String = "gpt-4o-mini-tts"    // speech synthesis model

    init() {}

    // decodeIfPresent so configs saved before a field existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-audio-mini"
        scriptModel = try c.decodeIfPresent(String.self, forKey: .scriptModel) ?? "gpt-4o-mini"
        ttsModel = try c.decodeIfPresent(String.self, forKey: .ttsModel) ?? "gpt-4o-mini-tts"
    }
}

// MARK: - Result types

struct AIExplanation: Equatable {
    let text: String      // the explanation in writing (for the on-screen sheet)
    let audio: Data?      // the same explanation spoken (mp3), for hands-free playback
}

/// Drives the AI-explain UI. `speaking.pending` is true while the explanation has
/// arrived but is waiting for a loop boundary before the voice starts.
enum AIExplainState: Equatable {
    case idle
    case preparing
    case waiting
    case speaking(text: String, pending: Bool)
    case error(String)
}

// MARK: - AIExplainer

/// Networking + caching for the audio-in explanation feature. Pure: it does not touch
/// playback. The view model orchestrates audio; this object just talks to the API.
final class AIExplainer: ObservableObject {

    @Published var config: AIConfig {
        didSet { persist() }
    }

    private var task: URLSessionDataTask?
    private var cache: [String: AIExplanation] = [:]

    private static let storageKey = "aiConfig_v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: AIExplainer.storageKey),
           let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            config = saved
        } else {
            config = AIConfig()
        }
    }

    var isConfigured: Bool {
        !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func cachedExplanation(for sentence: String) -> AIExplanation? {
        cache[cacheKey(sentence)]
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Lightweight auth/connectivity check: GET {base}/models. Validates URL + key without
    /// spending an audio call. Completion on the main thread.
    func testConnection(completion: @escaping (Result<Void, Error>) -> Void) {
        let finish: (Result<Void, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
        guard isConfigured else { finish(.failure(AIError.notConfigured)); return }
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else { finish(.failure(AIError.notConfigured)); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { finish(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else { finish(.failure(AIError.empty)); return }
            if (200...299).contains(http.statusCode) {
                finish(.success(()))
            } else {
                let msg = (data.flatMap(AIExplainer.apiErrorMessage)) ?? "HTTP \(http.statusCode)"
                finish(.failure(AIError.api(msg)))
            }
        }.resume()
    }

    /// Send a WAV clip of one sentence; the model listens and returns a spoken + written
    /// explanation. Completion is delivered on the main thread.
    func explain(audioClip: Data,
                 sentence: String,
                 completion: @escaping (Result<AIExplanation, Error>) -> Void) {

        guard let request = makeRequest(audioClip: audioClip) else {
            completion(.failure(AIError.notConfigured))
            return
        }

        task?.cancel()
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let finish: (Result<AIExplanation, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error { finish(.failure(error)); return }
            guard let data else { finish(.failure(AIError.empty)); return }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = AIExplainer.apiErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                finish(.failure(AIError.api(msg)))
                return
            }

            guard let explanation = AIExplainer.parse(data) else {
                finish(.failure(AIError.empty))
                return
            }
            self?.cache[self?.cacheKey(sentence) ?? sentence] = explanation
            finish(.success(explanation))
        }
        task?.resume()
    }

    // MARK: - Request building

    private func makeRequest(audioClip: Data) -> URLRequest? {
        guard isConfigured else { return nil }
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { return nil }

        let prompt = """
        You are a friendly English listening coach helping a learner who couldn't catch a \
        few seconds of fast natural English. Speak in clear, simple, SLOW English only — \
        do NOT use any Chinese. Cover exactly three things, briefly:
        1. What the speaker just said.
        2. Any tricky language — phrasal verbs, idioms, slang, or fixed expressions — \
        explained in plain words.
        3. How it really sounded: which words were reduced, linked, or swallowed \
        (for example "going to" sounding like "gonna").
        Keep it natural and under about 30 seconds. Speak slowly and clearly.
        """

        let body: [String: Any] = [
            "model": config.model,
            "modalities": ["text", "audio"],
            "audio": ["voice": "alloy", "format": "mp3"],
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "input_audio",
                     "input_audio": ["data": audioClip.base64EncodedString(), "format": "wav"]]
                ]]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response parsing

    /// Pulls the spoken transcript + audio out of an OpenAI audio chat completion.
    private static func parse(_ data: Data) -> AIExplanation? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }

        var text = ""
        var audio: Data?

        if let audioObj = message["audio"] as? [String: Any] {
            if let transcript = audioObj["transcript"] as? String { text = transcript }
            if let b64 = audioObj["data"] as? String { audio = Data(base64Encoded: b64) }
        }
        if text.isEmpty, let content = message["content"] as? String {
            text = content
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || audio != nil else { return nil }
        return AIExplanation(text: trimmed, audio: audio)
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let msg = err["message"] as? String else { return nil }
        return msg
    }

    // MARK: - Helpers

    private func cacheKey(_ sentence: String) -> String {
        config.model + "|" + sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: AIExplainer.storageKey)
        }
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case empty
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "AI 接口未配置")
        case .empty:         return String(localized: "AI 未返回内容")
        case .api(let m):    return m
        }
    }
}
