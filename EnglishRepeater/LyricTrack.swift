import Foundation

/// One lyric track for an audio. An audio can hold several (e.g. an imported LRC plus an
/// AI-recognized one); the user picks which is shown.
struct LyricTrack: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case lrc          // imported / bonded .lrc
        case recognized   // produced by on-device recognition
        case plainText    // a .txt transcript (no timing)

        /// Lower = preferred when nothing is explicitly selected. LRC > recognized > text.
        var priority: Int {
            switch self {
            case .lrc: return 0
            case .recognized: return 1
            case .plainText: return 2
            }
        }
        var tag: String {
            switch self {
            case .lrc: return "LRC"
            case .recognized: return String(localized: "AI 识别")
            case .plainText: return String(localized: "文本")
            }
        }
    }

    let id: UUID
    var name: String
    var kind: Kind
    var segments: [Segment]   // empty for plainText
    var plainText: String     // empty unless plainText
    var createdAt: Date

    init(id: UUID = UUID(), name: String, kind: Kind,
         segments: [Segment] = [], plainText: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.segments = segments
        self.plainText = plainText
        self.createdAt = createdAt
    }

    var displayText: String {
        segments.isEmpty ? plainText : segments.map { $0.text }.joined(separator: "\n")
    }
    var hasTiming: Bool { !segments.isEmpty }
}

/// The set of lyric tracks for one audio, plus which one is active.
struct LyricLibrary: Codable {
    var selectedID: UUID?
    var tracks: [LyricTrack] = []

    /// The track to display: the explicit selection, else the highest-priority one.
    var active: LyricTrack? {
        if let id = selectedID, let t = tracks.first(where: { $0.id == id }) { return t }
        return tracks.sorted { $0.kind.priority < $1.kind.priority }.first
    }
}
