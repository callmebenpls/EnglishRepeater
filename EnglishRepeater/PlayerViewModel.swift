import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

// MARK: - Button Action
enum ButtonAction: Codable, Hashable, Equatable {
    case none
    case togglePlay
    case skipBack(seconds: Int)
    case skipForward(seconds: Int)
    case repeatSentence
    case speakLastSentence

    static let allCases: [ButtonAction] = [
        .none,
        .togglePlay,
        .speakLastSentence,
        .repeatSentence,
        .skipBack(seconds: 3),
        .skipBack(seconds: 5),
        .skipBack(seconds: 10),
        .skipBack(seconds: 15),
        .skipBack(seconds: 30),
        .skipForward(seconds: 3),
        .skipForward(seconds: 5),
        .skipForward(seconds: 10),
        .skipForward(seconds: 15),
        .skipForward(seconds: 30),
    ]

    var displayName: String {
        switch self {
        case .none:                return "无动作"
        case .togglePlay:          return "暂停 / 播放"
        case .speakLastSentence:   return "清晰重读上一句"
        case .repeatSentence:      return "循环当前句"
        case .skipBack(let s):     return "后退 \(s) 秒"
        case .skipForward(let s):  return "前进 \(s) 秒"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, seconds }
    private enum ActionType: String, Codable {
        case none, togglePlay, skipBack, skipForward, repeatSentence, speakLastSentence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ActionType.self, forKey: .type) {
        case .none:              self = .none
        case .togglePlay:        self = .togglePlay
        case .repeatSentence:    self = .repeatSentence
        case .speakLastSentence: self = .speakLastSentence
        case .skipBack:          self = .skipBack(seconds: try c.decode(Int.self, forKey: .seconds))
        case .skipForward:       self = .skipForward(seconds: try c.decode(Int.self, forKey: .seconds))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:          try c.encode(ActionType.none, forKey: .type)
        case .togglePlay:    try c.encode(ActionType.togglePlay, forKey: .type)
        case .repeatSentence: try c.encode(ActionType.repeatSentence, forKey: .type)
        case .speakLastSentence: try c.encode(ActionType.speakLastSentence, forKey: .type)
        case .skipBack(let s):   try c.encode(ActionType.skipBack, forKey: .type); try c.encode(s, forKey: .seconds)
        case .skipForward(let s): try c.encode(ActionType.skipForward, forKey: .type); try c.encode(s, forKey: .seconds)
        }
    }
}

// MARK: - Key Mapping
struct KeyMapping: Codable {
    var singlePress: ButtonAction = .skipBack(seconds: 5)
    var doublePress: ButtonAction = .skipBack(seconds: 10)
    var triplePress: ButtonAction = .skipBack(seconds: 15)
}

// MARK: - PlayerViewModel
final class PlayerViewModel: NSObject, ObservableObject {

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentFileName = ""
    @Published var keyMapping = KeyMapping()
    @Published var library: [LibraryItem] = []
    @Published var currentItem: LibraryItem?
    @Published var displayText = ""
    @Published var playbackRate: Float = 1.0
    @Published var segments: [Segment] = []
    @Published var isGeneratingSubtitles = false
    @Published var subtitleProgress = ""
    /// Index into `segments` of the sentence currently being looped, or nil if not looping.
    @Published var loopingSegmentIndex: Int?
    /// True while the clear-voice re-speak of a sentence is playing.
    @Published var isRespeaking = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var cancellables = Set<AnyCancellable>()
    private let speechReader = SpeechReader()

    override init() {
        super.init()
        loadKeyMapping()
        loadPlaybackRate()
        loadLibrary()
        setupAudioSession()
        setupAutoSave()
        setupLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Auto-save

    private func setupAutoSave() {
        $keyMapping
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveKeyMapping() }
            .store(in: &cancellables)

        $library
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveLibrary() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Persist progress immediately when the app is backgrounded or about to terminate,
    /// so playback position survives being swiped away or killed by the system.
    private func setupLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(persistProgressNow),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(persistProgressNow),
                           name: UIApplication.willTerminateNotification, object: nil)
        center.addObserver(self, selector: #selector(persistProgressNow),
                           name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func persistProgressNow() {
        saveProgress()
        saveLibrary()   // synchronous write — bypass the debounced auto-save
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    // MARK: - Library

    func addToLibrary(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // If it's an LRC file, cache it and do not add to library
        if url.pathExtension.lowercased() == "lrc" {
            if let content = readLRCContent(from: url) {
                let baseName = url.deletingPathExtension().lastPathComponent
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let cacheURL = documents.appendingPathComponent(baseName + ".lrc")
                try? content.write(to: cacheURL, atomically: true, encoding: .utf8)
            }
            return
        }

        guard let bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        cacheLRCIfAvailable(for: url)

        let item = LibraryItem(
            id: UUID(),
            fileName: url.lastPathComponent,
            bookmarkData: bookmark,
            duration: 0,
            progress: 0,
            dateAdded: Date()
        )
        library.insert(item, at: 0)
    }

    func selectItem(_ item: LibraryItem) {
        saveProgress()
        load(item: item)
    }

    func removeItem(_ item: LibraryItem) {
        if currentItem?.id == item.id {
            stop()
            currentItem = nil
        }
        library.removeAll { $0.id == item.id }
    }

    // MARK: - Load / Play

    private var remoteCommandsConfigured = false

    private func load(item: LibraryItem) {
        stop()
        guard let url = item.resolvedURL else {
            print("Load error: could not resolve bookmark")
            return
        }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            cacheLRCIfAvailable(for: url)

            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.enableRate = true
            player?.rate = playbackRate
            player?.prepareToPlay()
            duration = player?.duration ?? item.duration
            currentTime = item.progress
            currentFileName = item.displayTitle
            currentItem = item
            updateItemDuration()
            setupRemoteCommandsIfNeeded()
            seek(to: item.progress)
            updateNowPlayingInfo()
            loadDisplayText(for: item, url: url)
            play()
        } catch {
            print("Load error: \(error)")
        }
    }

    private func updateItemDuration() {
        guard var item = currentItem else { return }
        item.duration = duration
        currentItem = item
        if let idx = library.firstIndex(where: { $0.id == item.id }) {
            library[idx].duration = duration
        }
    }

    func play() {
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        saveProgress()
        updateNowPlayingInfo()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loopingSegmentIndex = nil
        speechReader.stop()
        isRespeaking = false
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player?.currentTime = clamped
        currentTime = clamped
        updateNowPlayingInfo()
    }

    func skip(by delta: Double) {
        guard player != nil else { return }
        let target = max(0, min(currentTime + delta, duration))
        seek(to: target)
        if !isPlaying { play() }
    }

    func setRate(_ rate: Float) {
        let clamped = max(0.5, min(2.0, rate))
        let snapped = (clamped * 20).rounded() / 20
        playbackRate = snapped
        player?.rate = snapped
        UserDefaults.standard.set(snapped, forKey: "playbackRate_v1")
    }

    private func loadPlaybackRate() {
        if UserDefaults.standard.object(forKey: "playbackRate_v1") != nil {
            let saved = UserDefaults.standard.float(forKey: "playbackRate_v1")
            playbackRate = max(0.5, min(2.0, saved))
        }
    }

    // MARK: - Progress Save

    private func saveProgress() {
        guard let item = currentItem,
              let idx = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[idx].progress = currentTime
        currentItem?.progress = currentTime
    }

    // MARK: - Display Text (lyrics)

    private func readLRCContent(from url: URL) -> String? {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let gbkEnc = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(UInt32(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gbkEnc)
    }

    private func loadDisplayText(for item: LibraryItem, url: URL? = nil) {
        let audioURL: URL
        if let u = url {
            audioURL = u
        } else {
            guard let u = item.resolvedURL else { return }
            audioURL = u
        }

        // 1. Cached LRC from Documents
        let cachedLRC = lrcCachePath(for: audioURL)
        if let lrcSegments = parseLRC(from: cachedLRC) {
            segments = lrcSegments
            displayText = lrcSegments.map { $0.text }.joined(separator: "\n")
            return
        }

        // 2. Try original .lrc next to audio
        let originalLRC = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        if let lrcSegments = parseLRC(from: originalLRC) {
            if let content = readLRCContent(from: originalLRC) {
                try? content.write(to: cachedLRC, atomically: true, encoding: .utf8)
            }
            segments = lrcSegments
            displayText = lrcSegments.map { $0.text }.joined(separator: "\n")
            return
        }

        // 3. Generated segments
        let segmentsURL = segmentsFilePath(for: audioURL)
        if let data = try? Data(contentsOf: segmentsURL),
           let loaded = try? JSONDecoder().decode([Segment].self, from: data) {
            segments = loaded
            displayText = loaded.map { $0.text }.joined(separator: "\n")
            return
        }

        // 4. Plain text fallback
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        if let text = try? String(contentsOf: textURL, encoding: .utf8) {
            displayText = text
            segments = []
        } else {
            displayText = ""
            segments = []
        }
    }

    // MARK: - LRC Cache

    private func lrcCachePath(for url: URL) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = url.deletingPathExtension().lastPathComponent + ".lrc"
        return documents.appendingPathComponent(filename)
    }

    @discardableResult
    private func cacheLRCIfAvailable(for url: URL) -> Bool {
        let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
        if let content = readLRCContent(from: lrcURL) {
            try? content.write(to: lrcCachePath(for: url), atomically: true, encoding: .utf8)
            return true
        }
        return false
    }

    // MARK: - LRC Parser

    private func parseLRC(from url: URL) -> [Segment]? {
        guard let content = readLRCContent(from: url) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        var result: [Segment] = []
        guard let pattern = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})[.:](\\d{2,3})\\]") else {
            return nil
        }

        for line in lines {
            let fullRange = NSRange(line.startIndex..., in: line)
            let matches = pattern.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            // Text is whatever follows the last timestamp tag on this line.
            guard let lastMatch = matches.last,
                  let lastRange = Range(lastMatch.range, in: line) else { continue }
            let text = String(line[lastRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // A single line may carry multiple timestamps for the same text.
            for match in matches {
                guard let minRange = Range(match.range(at: 1), in: line),
                      let secRange = Range(match.range(at: 2), in: line),
                      let subRange = Range(match.range(at: 3), in: line),
                      let minutes = Double(line[minRange]),
                      let seconds = Double(line[secRange]),
                      let fraction = Double(line[subRange]) else { continue }

                // Divisor depends on how many fractional digits were written,
                // not the numeric value (e.g. "050" => 0.050, "05" => 0.05).
                let digits = subRange.upperBound.utf16Offset(in: line) - subRange.lowerBound.utf16Offset(in: line)
                let divisor = digits >= 3 ? 1000.0 : 100.0
                let start = minutes * 60 + seconds + fraction / divisor
                result.append(Segment(text: text, start: start, duration: 3))
            }
        }

        // Multiple timestamps across lines arrive out of order; sort by start.
        result.sort { $0.start < $1.start }

        for i in 0..<result.count {
            let nextStart = i + 1 < result.count ? result[i + 1].start : result[i].start + 5
            result[i] = Segment(text: result[i].text, start: result[i].start, duration: nextStart - result[i].start)
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Subtitle Generation

    private let speechRecognizer = SpeechRecognizer()

    func generateSubtitles(for item: LibraryItem) {
        guard let url = item.resolvedURL else { return }
        isGeneratingSubtitles = true
        subtitleProgress = ""

        speechRecognizer.onChunkComplete = { [weak self] segs in
            DispatchQueue.main.async {
                guard let self else { return }
                self.segments = segs
                self.displayText = segs.map { $0.text }.joined(separator: "\n")
            }
        }

        speechRecognizer.generateSubtitles(for: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGeneratingSubtitles = false
                self.speechRecognizer.onChunkComplete = nil
                switch result {
                case .success(let segs):
                    self.saveSegments(segs, for: url)
                    self.segments = segs
                    self.displayText = segs.map { $0.text }.joined(separator: "\n")
                case .failure(let error):
                    if self.segments.isEmpty {
                        self.subtitleProgress = "失败: \(error.localizedDescription)"
                    }
                }
            }
        }

        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.isGeneratingSubtitles { t.invalidate(); return }
            self.subtitleProgress = self.speechRecognizer.progress
        }
    }

    func cancelSubtitleGeneration() {
        speechRecognizer.cancel()
        isGeneratingSubtitles = false
    }

    private func saveSegments(_ segments: [Segment], for url: URL) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: segmentsFilePath(for: url))
    }

    private func segmentsFilePath(for url: URL) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = url.deletingPathExtension().lastPathComponent + ".segments.json"
        return documents.appendingPathComponent(filename)
    }

    // MARK: - Timer

    private var ticksSinceProgressSave = 0

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime

            // Sentence-loop: jump back to the sentence start when it ends.
            if let li = self.loopingSegmentIndex, li < self.segments.count {
                let seg = self.segments[li]
                let end = seg.start + seg.duration
                if player.currentTime >= end - 0.04 || player.currentTime < seg.start - 0.5 {
                    player.currentTime = seg.start
                    self.currentTime = seg.start
                }
            }

            // Persist progress roughly every 5s so it survives background playback and
            // an unexpected kill, not just explicit pause/switch.
            self.ticksSinceProgressSave += 1
            if self.ticksSinceProgressSave >= 20 {
                self.ticksSinceProgressSave = 0
                self.saveProgress()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

        let singlePressHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard let self else { return .commandFailed }
            self.executeAction(self.keyMapping.singlePress)
            return .success
        }

        // A single headphone/AirPods click is delivered as pause (while playing),
        // play (while paused), or toggle — depending on state and device. Route all
        // three through the single-press mapping so the user's setting always wins.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget(handler: singlePressHandler)

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget(handler: singlePressHandler)

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget(handler: singlePressHandler)

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.executeAction(self.keyMapping.doublePress)
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.executeAction(self.keyMapping.triplePress)
            return .success
        }
    }

    func executeAction(_ action: ButtonAction) {
        switch action {
        case .none:                    break
        case .togglePlay:              togglePlay()
        case .repeatSentence:          toggleRepeatSentence()
        case .speakLastSentence:       speakLastSentence()
        case .skipBack(let seconds):   skip(by: -Double(seconds))
        case .skipForward(let seconds): skip(by: Double(seconds))
        }
    }

    // MARK: - Re-speak Last Sentence

    /// Hands-free catch-up: pause the audio, re-speak the current sentence clearly with
    /// on-device TTS, then replay that original sentence and continue forward.
    func speakLastSentence() {
        // A second trigger while speaking acts as an interrupt: stop and resume.
        if isRespeaking {
            speechReader.stop()
            isRespeaking = false
            if !isPlaying { play() }
            return
        }

        guard !segments.isEmpty, let idx = currentSegmentIndex() else {
            announceNoTranscript()
            return
        }
        let seg = segments[idx]
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            announceNoTranscript()
            return
        }

        pause()
        isRespeaking = true
        speechReader.speak(text) { [weak self] in
            guard let self else { return }
            self.isRespeaking = false
            // Replay the original sentence at normal speed, then keep playing forward.
            self.seek(to: seg.start)
            self.play()
        }
    }

    /// Spoken feedback when there is no transcript to read (screen may be locked).
    private func announceNoTranscript() {
        pause()
        isRespeaking = true
        speechReader.speak("No transcript for this part yet.") { [weak self] in
            guard let self else { return }
            self.isRespeaking = false
        }
    }

    // MARK: - Sentence Loop

    /// Index of the sentence that is playing right now (latest segment whose start has passed).
    private func currentSegmentIndex() -> Int? {
        guard !segments.isEmpty else { return nil }
        var idx: Int?
        for (i, seg) in segments.enumerated() {
            if seg.start <= currentTime + 0.05 { idx = i } else { break }
        }
        return idx ?? 0
    }

    /// Toggle looping of the current sentence. Tap once to start, again to stop.
    func toggleRepeatSentence() {
        if loopingSegmentIndex != nil {
            loopingSegmentIndex = nil
            return
        }
        guard let idx = currentSegmentIndex() else { return }
        loopingSegmentIndex = idx
        seek(to: segments[idx].start)
        if !isPlaying { play() }
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: currentFileName.isEmpty ? "英语复读机" : currentFileName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Persist

    func saveKeyMapping() {
        if let data = try? JSONEncoder().encode(keyMapping) {
            UserDefaults.standard.set(data, forKey: "keyMapping_v2")
        }
    }

    private func loadKeyMapping() {
        if let data = UserDefaults.standard.data(forKey: "keyMapping_v2"),
           let mapping = try? JSONDecoder().decode(KeyMapping.self, from: data) {
            keyMapping = mapping
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: "library_v1")
        }
    }

    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: "library_v1"),
           let items = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            library = items
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension PlayerViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTimer()
            // Finished: reset saved position to 0 so reselecting starts over, not at the end.
            if let item = self.currentItem,
               let idx = self.library.firstIndex(where: { $0.id == item.id }) {
                self.library[idx].progress = 0
                self.currentItem?.progress = 0
            }
            self.saveLibrary()
        }
    }
}
