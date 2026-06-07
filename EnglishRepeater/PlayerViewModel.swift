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
    case aiExplain

    static let allCases: [ButtonAction] = [
        .none,
        .togglePlay,
        .aiExplain,
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
        case .aiExplain:           return "AI 听这句并讲解"
        case .repeatSentence:      return "循环当前句"
        case .skipBack(let s):     return "后退 \(s) 秒"
        case .skipForward(let s):  return "前进 \(s) 秒"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, seconds }
    private enum ActionType: String, Codable {
        case none, togglePlay, skipBack, skipForward, repeatSentence, aiExplain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ActionType.self, forKey: .type) {
        case .none:           self = .none
        case .togglePlay:     self = .togglePlay
        case .repeatSentence: self = .repeatSentence
        case .aiExplain:      self = .aiExplain
        case .skipBack:       self = .skipBack(seconds: try c.decode(Int.self, forKey: .seconds))
        case .skipForward:    self = .skipForward(seconds: try c.decode(Int.self, forKey: .seconds))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:          try c.encode(ActionType.none, forKey: .type)
        case .togglePlay:    try c.encode(ActionType.togglePlay, forKey: .type)
        case .repeatSentence: try c.encode(ActionType.repeatSentence, forKey: .type)
        case .aiExplain:     try c.encode(ActionType.aiExplain, forKey: .type)
        case .skipBack(let s):   try c.encode(ActionType.skipBack, forKey: .type); try c.encode(s, forKey: .seconds)
        case .skipForward(let s): try c.encode(ActionType.skipForward, forKey: .type); try c.encode(s, forKey: .seconds)
        }
    }
}

// MARK: - Subtitle Source

/// Where the currently-shown lyrics came from, so the UI can avoid blindly
/// re-recognizing audio that already has subtitles.
enum SubtitleSource: Equatable {
    case none          // no lyrics yet
    case lrc           // bonded .lrc file (imported / sibling)
    case generated     // produced by on-device recognition
    case plainText     // a plain .txt transcript (no timing)

    var label: String {
        switch self {
        case .none:      return "无字幕"
        case .lrc:       return "已绑定 LRC 字幕"
        case .generated: return "AI 识别的字幕"
        case .plainText: return "纯文本字幕"
        }
    }

    var hasLyrics: Bool { self != .none }
}

// MARK: - Key Mapping
struct KeyMapping: Codable {
    var singlePress: ButtonAction = .skipBack(seconds: 5)
    var doublePress: ButtonAction = .skipBack(seconds: 10)
    var triplePress: ButtonAction = .skipBack(seconds: 15)
}

// MARK: - PlayerViewModel
/// High-frequency playback time, kept in its own tiny observable so the 4×/second clock
/// updates only re-render the views that actually show time (the lyrics + progress bar) —
/// not the whole library / player. This is the key perf fix.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
}

final class PlayerViewModel: NSObject, ObservableObject {

    @Published var isPlaying = false
    @Published var duration: TimeInterval = 0

    /// Playback position. Lives on `clock` (separate observable) so updating it 4×/second
    /// does NOT fire this view model's objectWillChange. Internal code keeps using
    /// `currentTime` transparently via this forwarding accessor.
    let clock = PlaybackClock()
    var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    @Published var currentFileName = ""
    @Published var keyMapping = KeyMapping()
    @Published var library: [LibraryItem] = []
    @Published var folders: [Folder] = []
    @Published var currentItem: LibraryItem?
    @Published var displayText = ""
    @Published var playbackRate: Float = 1.0
    @Published var segments: [Segment] = []
    @Published var isGeneratingSubtitles = false
    @Published var subtitleProgress = ""
    @Published var subtitleSource: SubtitleSource = .none
    /// Index into `segments` of the sentence currently being looped, or nil if not looping.
    @Published var loopingSegmentIndex: Int?
    /// Drives the AI-explain UI (button, sheet, indicators).
    @Published var aiState: AIExplainState = .idle

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var cancellables = Set<AnyCancellable>()
    /// Off-main queue for JSON encode + UserDefaults writes so persistence never hitches
    /// the UI during playback.
    private let saveQueue = DispatchQueue(label: "EnglishRepeater.save", qos: .utility)
    let aiExplainer = AIExplainer()
    let stats = ListeningStats()
    private let cueSynth = AVSpeechSynthesizer()
    private var aiVoicePlayer: AVAudioPlayer?
    private var aiVoiceStartedAt: Date?

    // AI-explain in-flight bookkeeping
    private var aiSegment: Segment?
    private var aiPendingAudio: Data?       // explanation audio waiting for a loop boundary
    private var aiRateBeforeWait: Float = 1.0

    override init() {
        super.init()
        loadKeyMapping()
        loadPlaybackRate()
        loadLibrary()
        loadFolders()
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

        $folders
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveFolders() }
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
        // Synchronous writes here — the app may be suspending, so make sure they land.
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: "library_v1")
        }
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: "folders_v1")
        }
        stats.flush()
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

    /// Single-file entry point (Share / "open with" from other apps). Lands in 未分类.
    func addToLibrary(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "lrc" {
            cacheImportedLRC(url); return
        }
        guard !isDuplicate(url.lastPathComponent),
              let bookmark = try? url.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        cacheLRCIfAvailable(for: url)
        library.insert(LibraryItem(id: UUID(), fileName: url.lastPathComponent,
                                   bookmarkData: bookmark, duration: 0, progress: 0,
                                   dateAdded: Date()), at: 0)
    }

    private func isDuplicate(_ fileName: String) -> Bool {
        library.contains { $0.fileName.caseInsensitiveCompare(fileName) == .orderedSame }
    }

    private func cacheImportedLRC(_ url: URL) {
        guard let content = readLRCContent(from: url) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let cacheURL = documents.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".lrc")
        try? content.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Multi-file Import (review flow)

    /// Inspect picked URLs: cache any .lrc, bookmark audios, detect subtitle pairing and
    /// duplicates. Bookmarks/lrc are created NOW while we still hold the security scope.
    func prepareImport(urls: [URL]) -> ImportPlan {
        // 1. Cache every .lrc first so audio pairing can see them.
        for url in urls where url.pathExtension.lowercased() == "lrc" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            cacheImportedLRC(url)
        }
        // 2. Build a candidate per audio.
        var candidates: [ImportCandidate] = []
        for url in urls where url.pathExtension.lowercased() != "lrc"
                            && url.pathExtension.lowercased() != "txt" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData(options: .minimalBookmark,
                                                       includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }
            cacheLRCIfAvailable(for: url)
            let hasSub = FileManager.default.fileExists(atPath: lrcCachePath(for: url).path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            candidates.append(ImportCandidate(
                fileName: url.lastPathComponent,
                bookmark: bookmark,
                hasSubtitle: hasSub,
                isDuplicate: isDuplicate(url.lastPathComponent),
                sizeBytes: size.map(Int64.init)))
        }
        return ImportPlan(candidates: candidates)
    }

    /// Commit a reviewed plan into the chosen folder. Returns the number added.
    @discardableResult
    func commitImport(_ plan: ImportPlan, toFolder folderID: UUID?) -> Int {
        let fresh = plan.candidates.filter { !$0.isDuplicate }
        for c in fresh {
            library.insert(LibraryItem(id: UUID(), fileName: c.fileName, bookmarkData: c.bookmark,
                                       duration: 0, progress: 0, dateAdded: Date(),
                                       folderID: folderID), at: 0)
        }
        return fresh.count
    }

    // MARK: - Folders

    func createFolder(name: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let idx = folders.count
        let folder = Folder(name: trimmed.isEmpty ? "新文件夹" : trimmed,
                            colorIndex: idx % Theme.folderColors.count,
                            iconIndex: (idx + 1) % Theme.folderIcons.count,
                            order: idx)
        folders.append(folder)
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].name = trimmed
    }

    /// Delete a folder AND the audios inside it (per the chosen behavior). Stops playback
    /// if the current track was in this folder.
    func deleteFolder(_ folder: Folder) {
        let victims = library.filter { $0.folderID == folder.id }
        if let cur = currentItem, victims.contains(where: { $0.id == cur.id }) {
            stop(); currentItem = nil
        }
        library.removeAll { $0.folderID == folder.id }
        folders.removeAll { $0.id == folder.id }
    }

    func moveItem(_ item: LibraryItem, toFolder folderID: UUID?) {
        guard let i = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[i].folderID = folderID
        if currentItem?.id == item.id { currentItem?.folderID = folderID }
    }

    func items(in folderID: UUID?) -> [LibraryItem] {
        library.filter { $0.folderID == folderID }
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
        aiExplainer.cancel()
        cueSynth.stopSpeaking(at: .immediate)
        recordAIVoiceTime()
        aiVoicePlayer?.stop()
        aiVoicePlayer = nil
        aiPendingAudio = nil
        aiSegment = nil
        aiState = .idle
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
            subtitleSource = .lrc
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
            subtitleSource = .lrc
            return
        }

        // 3. Generated segments
        let segmentsURL = segmentsFilePath(for: audioURL)
        if let data = try? Data(contentsOf: segmentsURL),
           let loaded = try? JSONDecoder().decode([Segment].self, from: data) {
            segments = loaded
            displayText = loaded.map { $0.text }.joined(separator: "\n")
            subtitleSource = .generated
            return
        }

        // 4. Plain text fallback
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        if let text = try? String(contentsOf: textURL, encoding: .utf8) {
            displayText = text
            segments = []
            subtitleSource = .plainText
        } else {
            displayText = ""
            segments = []
            subtitleSource = .none
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

    /// Re-recognize, replacing whatever lyrics exist now (including bonded LRC). Removes
    /// the cached LRC + generated files so the new recognition result actually persists.
    func regenerateSubtitles(for item: LibraryItem) {
        guard let url = item.resolvedURL else { return }
        try? FileManager.default.removeItem(at: lrcCachePath(for: url))
        try? FileManager.default.removeItem(at: segmentsFilePath(for: url))
        segments = []
        displayText = ""
        subtitleSource = .none
        generateSubtitles(for: item)
    }

    /// Remove all lyrics for this audio (cached LRC + generated). Destructive.
    func clearSubtitles(for item: LibraryItem) {
        guard let url = item.resolvedURL else { return }
        try? FileManager.default.removeItem(at: lrcCachePath(for: url))
        try? FileManager.default.removeItem(at: segmentsFilePath(for: url))
        segments = []
        displayText = ""
        subtitleSource = .none
    }

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
                    self.subtitleSource = segs.isEmpty ? .none : .generated
                case .failure(let error):
                    if self.segments.isEmpty {
                        self.subtitleProgress = "失败: \(error.localizedDescription)"
                    }
                }
            }
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.isGeneratingSubtitles { t.invalidate(); return }
            // Only publish when the string actually changes — avoids re-rendering on every
            // tick while the percentage is unchanged.
            let p = self.speechRecognizer.progress
            if p != self.subtitleProgress { self.subtitleProgress = p }
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

            // Count this 0.25s as listening time whenever audio is genuinely playing.
            // The slow-loop wait state is included because the user is still hearing the
            // sentence; the only thing the main timer excludes is paused state.
            if player.isPlaying {
                self.stats.record(seconds: 0.25)
            }

            // Sentence-loop: jump back to the sentence start when it ends.
            if let li = self.loopingSegmentIndex, li < self.segments.count {
                let seg = self.segments[li]
                let end = seg.start + seg.duration
                if player.currentTime >= end - 0.04 || player.currentTime < seg.start - 0.5 {
                    // If an AI explanation arrived during the wait, play it at the boundary
                    // instead of looping again — avoids cutting a word mid-flow.
                    if let pending = self.aiPendingAudio {
                        self.aiPendingAudio = nil
                        if case .speaking(let t, _) = self.aiState {
                            self.aiState = .speaking(text: t, pending: false)
                        }
                        self.startAIPlayback(pending)
                        return
                    }
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
        case .aiExplain:               aiExplain()
        case .skipBack(let seconds):   skip(by: -Double(seconds))
        case .skipForward(let seconds): skip(by: Double(seconds))
        }
    }

    // MARK: - AI Explain (audio-in)

    /// Send the current sentence's audio to the AI, which listens and explains it.
    /// While waiting, the sentence slow-loops at 0.6x so the user can keep listening.
    /// Pressing again at any stage cancels and returns to normal playback.
    func aiExplain() {
        // Any press while busy acts as a cancel.
        switch aiState {
        case .idle, .error:
            break
        case .preparing, .waiting, .speaking:
            cancelAI()
            return
        }

        guard aiExplainer.isConfigured else {
            aiState = .error("请先在设置里填入 AI 接口和密钥")
            speakCue("AI is not set up yet.")
            return
        }
        guard !segments.isEmpty, let idx = currentSegmentIndex() else {
            aiState = .error("这一段没有字幕,无法解析")
            speakCue("No transcript here.")
            return
        }

        let seg = segments[idx]
        let sentence = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        aiSegment = seg
        aiPendingAudio = nil
        aiState = .preparing

        // Cache hit → skip the wait entirely.
        if let cached = aiExplainer.cachedExplanation(for: sentence) {
            pause()
            aiState = .speaking(text: cached.text, pending: false)
            startAIPlayback(cached.audio)
            return
        }

        guard let sourceURL = currentItem?.resolvedURL else {
            failAI("无法读取音频文件")
            return
        }

        // Begin the slow-loop from the sentence start while we wait.
        aiRateBeforeWait = playbackRate
        loopingSegmentIndex = idx
        seek(to: seg.start)
        player?.rate = 0.6
        if !isPlaying { play() }
        aiState = .waiting

        extractClip(from: sourceURL, start: seg.start, duration: seg.duration) { [weak self] clip in
            guard let self else { return }
            guard case .waiting = self.aiState, let clip else {
                if self.aiState != .idle { self.failAI("音频裁剪失败") }
                return
            }
            self.aiExplainer.explain(audioClip: clip, sentence: sentence) { [weak self] result in
                guard let self else { return }
                guard case .waiting = self.aiState else { return }  // cancelled meanwhile
                switch result {
                case .success(let explanation):
                    // Wait for the next loop boundary so we don't cut a word mid-flow.
                    self.aiPendingAudio = explanation.audio
                    self.aiState = .speaking(text: explanation.text, pending: true)
                case .failure(let error):
                    self.failAI(self.friendlyError(error))
                }
            }
        }
    }

    /// Cancel any in-flight or playing AI explanation and return to normal playback.
    func cancelAI() {
        aiExplainer.cancel()
        cueSynth.stopSpeaking(at: .immediate)
        recordAIVoiceTime()
        aiVoicePlayer?.stop()
        aiVoicePlayer = nil
        aiPendingAudio = nil
        loopingSegmentIndex = nil
        player?.rate = aiRateBeforeWait
        if let seg = aiSegment { seek(to: seg.start) }
        aiSegment = nil
        aiState = .idle
        if !isPlaying { play() }
    }

    private func failAI(_ message: String) {
        loopingSegmentIndex = nil
        aiPendingAudio = nil
        player?.rate = aiRateBeforeWait
        aiState = .error(message)
        speakCue("Sorry, the A I didn't respond.")
        // Resume the original sentence so the user isn't left in silence.
        if let seg = aiSegment { seek(to: seg.start) }
        if !isPlaying { play() }
    }

    /// Stop looping, play the AI's spoken explanation, then replay the sentence normally.
    private func startAIPlayback(_ audio: Data?) {
        loopingSegmentIndex = nil
        player?.pause()
        player?.rate = aiRateBeforeWait
        isPlaying = false

        guard let audio, let voice = try? AVAudioPlayer(data: audio) else {
            // No audio came back — just replay the sentence.
            finishAIAndResume()
            return
        }
        aiVoicePlayer = voice
        voice.delegate = self
        voice.numberOfLoops = -1   // repeat the explanation until the user closes the sheet
        aiVoiceStartedAt = Date()
        voice.play()
    }

    /// Credit any AI-voice playback time to the stats, then clear the marker.
    private func recordAIVoiceTime() {
        if let start = aiVoiceStartedAt {
            stats.record(seconds: Date().timeIntervalSince(start))
            aiVoiceStartedAt = nil
        }
    }

    /// Called when the AI voice finishes (or had no audio): replay the sentence, continue.
    private func finishAIAndResume() {
        recordAIVoiceTime()
        aiVoicePlayer = nil
        aiState = .idle
        if let seg = aiSegment { seek(to: seg.start) }
        aiSegment = nil
        play()
    }

    private func speakCue(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.46
        cueSynth.speak(u)
    }

    private func friendlyError(_ error: Error) -> String {
        if (error as? URLError)?.code == .timedOut { return "AI 响应超时,请重试" }
        if let urlErr = error as? URLError { return "网络错误: \(urlErr.localizedDescription)" }
        // AIError.api carries the actual server message — surface it.
        if let aiErr = error as? AIError, let msg = aiErr.errorDescription { return msg }
        return error.localizedDescription
    }

    // MARK: - Audio Clip Extraction

    /// Read a small WAV clip for [start, start+duration] (with a little padding so word
    /// edges aren't clipped). WAV because OpenAI's input_audio accepts wav/mp3, not m4a.
    /// Returns the clip bytes on the main thread.
    private func extractClip(from url: URL,
                             start: TimeInterval,
                             duration: TimeInterval,
                             completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: outURL) }

            do {
                let src = try AVAudioFile(forReading: url)
                let format = src.processingFormat
                let sr = format.sampleRate
                let totalFrames = src.length
                let total = Double(totalFrames) / sr

                // Clamp the requested window inside the file. A bad transcript can give
                // segments past EOF; without clamping, read() returns 0 frames and we
                // ship an empty WAV that the API rejects.
                let from = max(0, min(start - 0.15, total - 0.05))
                let maxLen = max(0, total - from)
                let len = min(duration + 0.4, maxLen)
                guard len >= 0.1 else {
                    DispatchQueue.main.async { completion(nil) }; return
                }

                let frameCount = AVAudioFrameCount(len * sr)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                src.framePosition = AVAudioFramePosition(from * sr)
                try src.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else {
                    DispatchQueue.main.async { completion(nil) }; return
                }

                // Use the source's processingFormat for the output settings too. Writing
                // Float32 PCM WAV directly avoids the Int16 conversion path that was
                // triggering "mBuffers[0].mDataByteSize (0) should be non-zero" warnings.
                let out = try AVAudioFile(forWriting: outURL,
                                          settings: format.settings,
                                          commonFormat: format.commonFormat,
                                          interleaved: format.isInterleaved)
                try out.write(from: buffer)

                let data = try? Data(contentsOf: outURL)
                if (data?.count ?? 0) < 100 {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                DispatchQueue.main.async { completion(data) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
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
        let snapshot = library   // value copy; encode off the main thread
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "library_v1")
            }
        }
    }

    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: "library_v1"),
           let items = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            library = items
        }
    }

    private func saveFolders() {
        let snapshot = folders
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "folders_v1")
            }
        }
    }

    private func loadFolders() {
        if let data = UserDefaults.standard.data(forKey: "folders_v1"),
           let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = decoded
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension PlayerViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // AI explanation voice finished → replay the original sentence and continue.
        if player === aiVoicePlayer {
            DispatchQueue.main.async { self.finishAIAndResume() }
            return
        }
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
