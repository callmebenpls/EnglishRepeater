import Foundation

/// A user-created folder. One audio belongs to at most one folder (folderID on the item);
/// items with no folder live in the implicit "未分类" bucket.
struct Folder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int     // index into Theme.folderColors
    var iconIndex: Int      // index into Theme.folderIcons
    var order: Int

    init(id: UUID = UUID(), name: String, colorIndex: Int = 0, iconIndex: Int = 0, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.iconIndex = iconIndex
        self.order = order
    }
}

// MARK: - Import flow models

/// One audio being imported, with pairing/dup status detected up front.
struct ImportCandidate: Identifiable {
    let id = UUID()
    let fileName: String
    let bookmark: Data
    let hasSubtitle: Bool
    let isDuplicate: Bool
    let sizeBytes: Int64?

    var displayTitle: String {
        var n = fileName
        for ext in [".mp3", ".m4a", ".wav", ".aac", ".caf", ".aiff"] {
            if n.lowercased().hasSuffix(ext) { n = String(n.dropLast(ext.count)); break }
        }
        return n
    }
}

struct ImportPlan: Identifiable {
    let id = UUID()
    var candidates: [ImportCandidate]
    var newCandidates: [ImportCandidate] { candidates.filter { !$0.isDuplicate } }
    var newCount: Int { newCandidates.count }
    var withSubtitleCount: Int { newCandidates.filter { $0.hasSubtitle }.count }
    var duplicateCount: Int { candidates.filter { $0.isDuplicate }.count }
    var isEmpty: Bool { candidates.isEmpty }
}
