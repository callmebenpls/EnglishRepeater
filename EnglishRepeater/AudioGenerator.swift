import Foundation
import AVFoundation

// MARK: - Generated content models

enum LangPointCategory: String, Codable, CaseIterable {
    case idiom, slang, phrasalVerb, spoken

    var label: String {
        switch self {
        case .idiom:       return String(localized: "习语")
        case .slang:       return String(localized: "俚语")
        case .phrasalVerb: return String(localized: "短语动词")
        case .spoken:      return String(localized: "口语表达")
        }
    }
}

struct GenLine: Codable, Equatable {
    var speaker: String     // "A" / "B"; "" for monologue
    var en: String
    var zh: String
}

struct LangPoint: Codable, Equatable, Identifiable {
    var id: String { phrase }
    var category: LangPointCategory
    var phrase: String
    var explanation: String     // Chinese explanation
}

struct VocabItem: Codable, Equatable, Identifiable {
    var id: String { word }
    var word: String
    var pos: String             // n. / v. / adj. ...
    var zh: String
}

struct ExpressionItem: Codable, Equatable, Identifiable {
    var id: String { phrase }
    var phrase: String
    var zh: String
}

/// Everything one generation produces besides the audio itself. Persisted as a
/// `<audio>.notes.json` sidecar so the player can reopen it anytime.
struct GeneratedPack: Codable, Equatable {
    var title: String
    var lines: [GenLine]
    var points: [LangPoint]
    var vocab: [VocabItem]
    var expressions: [ExpressionItem]
}

// MARK: - Options

struct GenerationOptions {
    var prompt = ""
    var register = 1                 // 0 textbook · 1 natural · 2 slang-heavy
    var minutes = 2                  // 1 / 2 / 3 / 5
    var categories: Set<LangPointCategory> = [.idiom, .slang, .phrasalVerb, .spoken]
    var density = 1                  // 0 few · 1 medium · 2 many
    var level = "B1"                 // A2 / B1 / B2 / C1
    var dialogue = true
    var slowPace = false
    var voiceA = "nova"
    var voiceB = "onyx"

    var targetPointCount: Int {
        let perMinute = [2, 4, 7][density]
        return max(categories.count, perMinute * minutes)
    }
}

struct VoiceInfo: Identifiable {
    let id: String          // API voice name
    let descriptionKey: String
    static let all: [VoiceInfo] = [
        VoiceInfo(id: "nova",    descriptionKey: String(localized: "女 · 清亮自然")),
        VoiceInfo(id: "shimmer", descriptionKey: String(localized: "女 · 温柔")),
        VoiceInfo(id: "coral",   descriptionKey: String(localized: "女 · 活泼")),
        VoiceInfo(id: "alloy",   descriptionKey: String(localized: "中性 · 平和")),
        VoiceInfo(id: "echo",    descriptionKey: String(localized: "男 · 沉稳")),
        VoiceInfo(id: "onyx",    descriptionKey: String(localized: "男 · 低沉")),
        VoiceInfo(id: "fable",   descriptionKey: String(localized: "英音 · 叙事感")),
    ]
}

// MARK: - AudioGenerator

/// Script generation + speech synthesis over the OpenAI-compatible endpoint in `AIConfig`,
/// plus per-line stitching into a single m4a with exact line timings by construction.
final class AudioGenerator {

    private let config: AIConfig
    init(config: AIConfig) { self.config = config }

    private var base: String {
        config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func request(path: String, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw AIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespaces))",
                     forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            throw AIError.api(msg)
        }
        throw AIError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }

    // MARK: Script

    func generateScript(options: GenerationOptions) async throws -> GeneratedPack {
        let registers = ["clean, textbook-style English, no slang",
                         "natural everyday spoken English, the way native speakers casually talk",
                         "very informal English packed with current slang and casual speech"]
        let cats = options.categories.map { $0.rawValue }.joined(separator: ", ")
        let form = options.dialogue
            ? "a two-person dialogue (speakers \"A\" and \"B\")"
            : "a monologue by a single speaker (speaker \"\")"
        let words = options.minutes * 130

        let system = """
        You write listening-practice scripts for Chinese learners of English. Respond with ONLY \
        a JSON object, no markdown, matching exactly this schema:
        {"title": string (short English title),
         "lines": [{"speaker": "A"|"B"|"", "en": string, "zh": string (natural Simplified Chinese translation)}],
         "points": [{"category": "idiom"|"slang"|"phrasalVerb"|"spoken", "phrase": string, "explanation": string (Chinese, explain meaning + usage + one similar expression)}],
         "vocab": [{"word": string, "pos": string like "n."|"v."|"adj.", "zh": string}],
         "expressions": [{"phrase": string, "zh": string}]}
        Every language point in "points" MUST literally appear inside some line's "en" text. \
        Keep each line short enough to be one subtitle (max ~15 words).
        """
        let user = """
        Topic/scene: \(options.prompt.isEmpty ? "everyday small talk" : options.prompt)
        Form: \(form). Length: about \(words) English words (~\(options.minutes) minutes spoken).
        Style: \(registers[options.register]). Learner level: \(options.level) — keep grammar/vocab around that level.
        Include exactly \(options.targetPointCount) language points total, drawn only from these categories: \(cats). \
        Spread them across the categories. Also list 6-8 useful vocab words and 3-5 useful expressions from the script.
        """

        let body: [String: Any] = [
            "model": config.scriptModel,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]]
        ]
        let (data, response) = try await URLSession.shared.data(for: request(path: "/chat/completions", body: body, timeout: 120))
        try Self.check(data, response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let packData = content.data(using: .utf8),
              let pack = try? JSONDecoder().decode(GeneratedPack.self, from: packData),
              !pack.lines.isEmpty
        else { throw AIError.empty }
        return pack
    }

    // MARK: Speech

    /// One line → WAV data from the TTS endpoint.
    func synthesize(text: String, voice: String, slow: Bool) async throws -> Data {
        let body: [String: Any] = [
            "model": config.ttsModel,
            "voice": voice,
            "input": text,
            "response_format": "wav",
            "speed": slow ? 0.85 : 1.0
        ]
        let (data, response) = try await URLSession.shared.data(for: request(path: "/audio/speech", body: body, timeout: 60))
        try Self.check(data, response)
        guard data.count > 200 else { throw AIError.empty }
        return data
    }

    /// Synthesize every line (voice per speaker), stitch into one m4a in Documents, and
    /// return exact per-line segments. `onProgress(done, total)` fires per finished line.
    func synthesizeAll(pack: GeneratedPack, options: GenerationOptions,
                       onProgress: @escaping (Int, Int) -> Void) async throws -> (URL, [Segment]) {
        let total = pack.lines.count
        var clips = [Data?](repeating: nil, count: total)
        var done = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func add(_ i: Int) {
                let line = pack.lines[i]
                let voice = (line.speaker == "B") ? options.voiceB : options.voiceA
                group.addTask { (i, try await self.synthesize(text: line.en, voice: voice, slow: options.slowPace)) }
            }
            while next < min(3, total) { add(next); next += 1 }
            for try await (i, data) in group {
                clips[i] = data
                done += 1
                let d = done
                await MainActor.run { onProgress(d, total) }
                if next < total { add(next); next += 1 }
            }
        }

        return try Self.stitch(clips: clips.compactMap { $0 }, lines: pack.lines, title: pack.title)
    }

    /// Decode the WAV clips and append them into a single AAC m4a, with a short pause
    /// between lines. Line timings fall out of the running frame count — exact by construction.
    private static func stitch(clips: [Data], lines: [GenLine], title: String) throws -> (URL, [Segment]) {
        guard clips.count == lines.count, !clips.isEmpty else { throw AIError.empty }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Unique output name from the title.
        var safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        if safe.isEmpty { safe = "AI Audio" }
        var outURL = documents.appendingPathComponent(safe + ".m4a")
        var n = 2
        while fm.fileExists(atPath: outURL.path) {
            outURL = documents.appendingPathComponent("\(safe) \(n).m4a"); n += 1
        }

        // Open the first clip to learn the PCM format.
        let firstURL = tmp.appendingPathComponent(UUID().uuidString + ".wav")
        try clips[0].write(to: firstURL)
        let probe = try AVAudioFile(forReading: firstURL)
        let format = probe.processingFormat
        let sr = format.sampleRate

        let out = try AVAudioFile(forWriting: outURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        let gapFrames = AVAudioFrameCount(sr * 0.35)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: gapFrames)!
        silence.frameLength = gapFrames

        var cursor: Double = 0
        var segments: [Segment] = []

        for (i, clip) in clips.enumerated() {
            let clipURL = i == 0 ? firstURL : tmp.appendingPathComponent(UUID().uuidString + ".wav")
            if i > 0 { try clip.write(to: clipURL) }
            defer { try? fm.removeItem(at: clipURL) }

            let file = try AVAudioFile(forReading: clipURL)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buf)
            try out.write(from: buf)

            let dur = Double(buf.frameLength) / sr
            segments.append(Segment(text: lines[i].en, start: cursor, duration: dur))
            cursor += dur

            if i < clips.count - 1 {
                try out.write(from: silence)
                cursor += Double(gapFrames) / sr
            }
        }
        return (outURL, segments)
    }

    // MARK: Voice previews

    static func previewCacheURL(voice: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoicePreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(voice + ".wav")
    }

    /// Returns cached sample audio for a voice, synthesizing it once if needed.
    func previewSample(voice: String) async throws -> URL {
        let url = Self.previewCacheURL(voice: voice)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await synthesize(text: "Hey there! This is what I sound like.", voice: voice, slow: false)
        try data.write(to: url)
        return url
    }
}
