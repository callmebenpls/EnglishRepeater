import Foundation

struct LibraryItem: Identifiable, Codable {
    let id: UUID
    var fileName: String
    var bookmarkData: Data
    var duration: TimeInterval
    var progress: TimeInterval
    var dateAdded: Date
    /// Folder this audio belongs to; nil = 未分类 (unsorted). Optional so older saved
    /// libraries decode cleanly (missing key → nil).
    var folderID: UUID? = nil

    var resolvedURL: URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    var displayTitle: String {
        fileName.replacingOccurrences(of: ".mp3", with: "")
            .replacingOccurrences(of: ".m4a", with: "")
            .replacingOccurrences(of: ".wav", with: "")
            .replacingOccurrences(of: ".aac", with: "")
    }

    var initials: String {
        let name = displayTitle
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1)) + String(words[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(progress / duration, 1.0)
    }
}
