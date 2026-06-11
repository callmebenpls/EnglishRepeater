import Foundation
import Speech
import AVFoundation

struct Segment: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

final class SpeechRecognizer: ObservableObject {

    @Published var isRunning = false
    @Published var progress: String = ""

    private var currentTask: SFSpeechRecognitionTask?
    private var modernTask: Task<Void, Never>?
    var onChunkComplete: (([Segment]) -> Void)?

    func generateSubtitles(
        for url: URL,
        completion: @escaping (Result<[Segment], Error>) -> Void
    ) {
        if #available(iOS 26.0, *) {
            isRunning = true
            progress = String(localized: "正在准备...")
            modernTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transcribeModern(url: url, completion: completion)
                } catch is CancellationError {
                    await MainActor.run {
                        self.isRunning = false
                        self.progress = ""
                        completion(.success([]))
                    }
                } catch {
                    // Setup failed (locale unsupported, model download, unreadable file) —
                    // fall back to the proven chunked SFSpeechRecognizer path.
                    await MainActor.run {
                        self.legacyGenerateSubtitles(for: url, completion: completion)
                    }
                }
            }
        } else {
            legacyGenerateSubtitles(for: url, completion: completion)
        }
    }

    func cancel() {
        isRunning = false
        currentTask?.cancel()
        modernTask?.cancel()
        progress = ""
    }

    // MARK: - Modern path (iOS 26+, SpeechAnalyzer)

    /// Single-pass file transcription via SpeechAnalyzer/SpeechTranscriber: no 50-second
    /// chunking, model-grade punctuation and capitalization, per-word audio time ranges.
    /// Throws only during setup (the caller falls back to the legacy path); errors after
    /// analysis has produced results degrade to a partial success instead.
    @available(iOS 26.0, *)
    private func transcribeModern(url: URL,
                                  completion: @escaping (Result<[Segment], Error>) -> Void) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == "en-US" })
                ?? supported.first(where: { $0.identifier(.bcp47).hasPrefix("en") }) else {
            throw NSError(domain: "Speech", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // First run downloads the on-device model; cached for every run after.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MainActor.run { self.progress = String(localized: "正在下载语音模型…") }
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let totalDuration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results while the analyzer chews through the file. Word segments
        // accumulate here; lines are re-grouped per result so the lyrics fill in live.
        let consumer = Task { [weak self] () -> [Segment] in
            var words: [Segment] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    guard let self, self.isRunning, !Task.isCancelled else { break }
                    words.append(contentsOf: Self.words(from: result.text))
                    let lines = Self.prettify(words: words)
                    let lastEnd = words.last.map { $0.start + $0.duration } ?? 0
                    let pct = totalDuration > 0 ? min(99, Int(lastEnd / totalDuration * 100)) : 0
                    await MainActor.run {
                        self.progress = String(localized: "识别中...") + " \(pct)%"
                        self.onChunkComplete?(lines)
                    }
                }
            } catch { }   // analysis-side errors surface below; keep partial words
            return words
        }

        var analysisError: Error?
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                try await analyzer.cancelAndFinishNow()
            }
        } catch {
            analysisError = error
            consumer.cancel()
            try? await analyzer.cancelAndFinishNow()
        }

        let lines = Self.prettify(words: await consumer.value)
        await MainActor.run {
            self.isRunning = false
            self.progress = ""
            if let error = analysisError, lines.isEmpty, !(error is CancellationError) {
                completion(.failure(error))
            } else {
                completion(.success(lines))
            }
        }
    }

    /// Flattens a final transcription into word-level segments. Runs carry `audioTimeRange`
    /// attributes; multi-word runs are split with their range interpolated by word index.
    @available(iOS 26.0, *)
    private static func words(from text: AttributedString) -> [Segment] {
        var out: [Segment] = []
        for run in text.runs {
            let sub = String(text.characters[run.range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sub.isEmpty else { continue }
            guard let range = run.audioTimeRange else {
                // Untimed run (stray punctuation) — glue onto the previous word.
                if let last = out.last {
                    out[out.count - 1] = Segment(text: last.text + sub,
                                                 start: last.start, duration: last.duration)
                }
                continue
            }
            let start = range.start.seconds
            let end = range.end.seconds
            let tokens = sub.split(whereSeparator: \.isWhitespace).map(String.init)
            let n = Double(tokens.count)
            for (i, token) in tokens.enumerated() {
                let ts = start + (end - start) * Double(i) / n
                let te = start + (end - start) * Double(i + 1) / n
                out.append(Segment(text: token, start: ts, duration: te - ts))
            }
        }
        return out
    }

    // MARK: - Line shaping

    /// Groups word segments into sentence-shaped subtitle lines: break on sentence-ending
    /// punctuation, soft-break at clause punctuation once a line is long enough, and
    /// hard-cap runaway sentences. Replaces the old fixed 3–8 word grouping.
    static func prettify(words: [Segment]) -> [Segment] {
        let softLimit = 9      // clause punctuation may end the line from here
        let hardLimit = 14     // unconditional break
        var lines: [Segment] = []
        var current: [Segment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.text }.joined(separator: " ")
            let end = last.start + last.duration
            lines.append(Segment(text: text, start: first.start,
                                 duration: max(0.3, end - first.start)))
            current = []
        }

        for word in words {
            current.append(word)
            let trimmed = word.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]"))
            guard let lastChar = trimmed.last else { continue }
            let endsSentence = ".?!…。？！".contains(lastChar)
            let endsClause = ",;:，；：".contains(lastChar)
            if endsSentence || (endsClause && current.count >= softLimit) || current.count >= hardLimit {
                flush()
            }
        }
        flush()
        return lines
    }

    // MARK: - Legacy path (pre-iOS 26, chunked SFSpeechRecognizer)

    private func legacyGenerateSubtitles(
        for url: URL,
        completion: @escaping (Result<[Segment], Error>) -> Void
    ) {

        isRunning = true
        progress = String(localized: "正在准备...")

        let locale = Locale(identifier: "en-US")
        let recognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = recognizer, recognizer.isAvailable else {
            completion(.failure(NSError(domain: "Speech", code: -1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])))
            isRunning = false
            return
        }

        // Open file on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard let file = try? AVAudioFile(forReading: url) else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    completion(.failure(NSError(domain: "Speech", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "无法读取音频文件")])))
                }
                return
            }

            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let totalFrames = Double(file.length)
            let audioDuration = totalFrames / sampleRate
            let chunkDuration: Double = 50
            let totalChunks = max(1, Int(ceil(audioDuration / chunkDuration)))

            DispatchQueue.main.async {
                self.progress = String(localized: "识别中...") + " 0%"
            }

            self.runChunk(
                recognizer: recognizer,
                file: file,
                format: format,
                chunkIndex: 0,
                totalChunks: totalChunks,
                chunkDuration: chunkDuration,
                allSegments: [],
                completion: { result in
                    DispatchQueue.main.async {
                        self.isRunning = false
                        completion(result)
                    }
                }
            )
        }
    }

    private func runChunk(
        recognizer: SFSpeechRecognizer,
        file: AVAudioFile,
        format: AVAudioFormat,
        chunkIndex: Int,
        totalChunks: Int,
        chunkDuration: Double,
        allSegments: [Segment],
        completion: @escaping (Result<[Segment], Error>) -> Void
    ) {
        guard isRunning else {
            completion(.success(allSegments))
            return
        }

        let sampleRate = format.sampleRate
        let startOffset = Double(chunkIndex) * chunkDuration * sampleRate
        let endOffset = Double(chunkIndex + 1) * chunkDuration * sampleRate
        let fileLength = Double(file.length)

        // Check we haven't gone past the end
        if startOffset >= fileLength {
            completion(.success(allSegments))
            return
        }

        let pct = min(100, Int(Double(chunkIndex) / Double(totalChunks) * 100))
        DispatchQueue.main.async {
            self.progress = String(localized: "识别中...") + " \(pct)%"
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Punctuation + capitalization → readable text and real sentence boundaries.
        request.addsPunctuation = true
        // Prefer on-device: offline, private, and no 1-minute server limit (which is what
        // forces the chunking in the first place).
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error = error as NSError? {
                let isAssistant = error.domain == "kAFAssistantErrorDomain"
                if isAssistant {
                    // Skip this chunk, continue with next
                    self.runChunk(
                        recognizer: recognizer,
                        file: file,
                        format: format,
                        chunkIndex: chunkIndex + 1,
                        totalChunks: totalChunks,
                        chunkDuration: chunkDuration,
                        allSegments: allSegments,
                        completion: completion
                    )
                    return
                }
                completion(.failure(error))
                return
            }

            if let result = result, result.isFinal {
                let offset = Double(chunkIndex) * chunkDuration
                let segs = result.bestTranscription.segments.map { seg in
                    Segment(
                        text: seg.substring.trimmingCharacters(in: .whitespaces),
                        start: seg.timestamp + offset,
                        duration: seg.duration
                    )
                }
                let grouped = Self.prettify(words: segs)
                var updated = allSegments
                updated.append(contentsOf: grouped)

                DispatchQueue.main.async {
                    self.onChunkComplete?(updated)
                }

                self.runChunk(
                    recognizer: recognizer,
                    file: file,
                    format: format,
                    chunkIndex: chunkIndex + 1,
                    totalChunks: totalChunks,
                    chunkDuration: chunkDuration,
                    allSegments: updated,
                    completion: completion
                )
            }
        }

        // Feed audio for this chunk
        file.framePosition = AVAudioFramePosition(startOffset)

        let bufferSize = AVAudioFrameCount(min(sampleRate * 0.25, endOffset - startOffset))
        let maxPosition = min(fileLength, endOffset)

        while file.framePosition < AVAudioFramePosition(maxPosition) && isRunning {
            let remaining = maxPosition - Double(file.framePosition)
            let frames = AVAudioFrameCount(min(Double(bufferSize), remaining))
            guard frames > 0 else { break }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frames
            ) else { break }

            do {
                try file.read(into: buffer, frameCount: frames)
                request.append(buffer)
            } catch {
                break
            }
        }

        request.endAudio()
    }
}
