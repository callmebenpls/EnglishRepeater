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
    var onChunkComplete: (([Segment]) -> Void)?

    func generateSubtitles(
        for url: URL,
        completion: @escaping (Result<[Segment], Error>) -> Void
    ) {

        isRunning = true
        progress = "正在准备..."

        let locale = Locale(identifier: "en-US")
        let recognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = recognizer, recognizer.isAvailable else {
            completion(.failure(NSError(domain: "Speech", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])))
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
                        userInfo: [NSLocalizedDescriptionKey: "无法读取音频文件"])))
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
                self.progress = "识别中... 0%"
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
            self.progress = "识别中... \(pct)%"
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
                let grouped = self.groupSegments(from: segs)
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

    private func groupSegments(from segments: [Segment]) -> [Segment] {
        let minWords = 3
        let maxWords = 8
        var result: [Segment] = []
        var current: [Segment] = []

        for seg in segments {
            current.append(seg)
            let hasPunct = seg.text.hasSuffix(".") || seg.text.hasSuffix("?") || seg.text.hasSuffix("!")

            if (hasPunct && current.count >= minWords) || current.count >= maxWords {
                let text = current.map { $0.text }.joined(separator: " ")
                let start = current.first?.start ?? 0
                let end = (current.last?.start ?? start) + (current.last?.duration ?? 0)
                result.append(Segment(text: text, start: start, duration: end - start))
                current = []
            }
        }

        if !current.isEmpty {
            let text = current.map { $0.text }.joined(separator: " ")
            let start = current.first?.start ?? 0
            let end = (current.last?.start ?? start) + (current.last?.duration ?? 0)
            result.append(Segment(text: text, start: start, duration: end - start))
        }

        return result
    }

    func cancel() {
        isRunning = false
        currentTask?.cancel()
        progress = ""
    }
}
