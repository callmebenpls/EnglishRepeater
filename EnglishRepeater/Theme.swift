import SwiftUI

/// Build-time feature flags.
enum Features {
    /// AI lecture (audio-in explain). Re-enabled 2026-06-11: the app now exposes the
    /// BYO-key AI 接口 settings for audio generation anyway, so the explain feature
    /// shares that same config rather than hiding behind a backend that never shipped.
    static let aiEnabled = true
}

/// Warm & encouraging design tokens. Centralized so every screen shares one identity:
/// cream canvas, coral→amber accent, soft borders. Light-first (the app's listening
/// context is daytime study); a dark variant can layer on later.
enum Theme {
    // Accent
    static let accent      = Color(red: 0.949, green: 0.392, blue: 0.231)   // #F2643B coral
    static let accentHi    = Color(red: 1.000, green: 0.541, blue: 0.357)   // #FF8A5B (gradient top)
    static let accentSoft  = Color(red: 1.000, green: 0.851, blue: 0.780)   // #FFD9C7 tinted bg

    // Surfaces
    static let canvas      = Color(red: 1.000, green: 0.969, blue: 0.941)   // #FFF7F0
    static let card        = Color.white
    static let border      = Color(red: 0.945, green: 0.878, blue: 0.824)   // #F1E0D2
    static let chip        = Color(red: 0.984, green: 0.906, blue: 0.847)   // #FBE7D8

    // Text
    static let textPrimary   = Color(red: 0.165, green: 0.125, blue: 0.094) // #2A2018
    static let textSecondary = Color(red: 0.690, green: 0.541, blue: 0.431) // #B08A6E
    static let textTertiary  = Color(red: 0.780, green: 0.604, blue: 0.486) // #C79A7C

    // Status accents (folder icons, progress states)
    static let green  = Color(red: 0.310, green: 0.620, blue: 0.341)
    static let greenBg = Color(red: 0.906, green: 0.953, blue: 0.902)

    static let accentGradient = LinearGradient(
        colors: [accentHi, accent],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cornerRadius: CGFloat = 16

    /// Palette for folder icon tiles — index stored on each Folder.
    static let folderColors: [(bg: Color, fg: Color)] = [
        (accentSoft, accent),
        (chip, Color(red: 0.722, green: 0.541, blue: 0.392)),
        (greenBg, green),
        (Color(red: 0.901, green: 0.902, blue: 0.980), Color(red: 0.298, green: 0.357, blue: 0.831)),
        (border, Color(red: 0.604, green: 0.416, blue: 0.282))
    ]

    static let folderIcons = ["music.note", "tv", "mic", "graduationcap", "headphones", "star", "books.vertical"]
}

extension View {
    /// Standard warm card background + hairline border.
    func warmCard(radius: CGFloat = Theme.cornerRadius) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5))
    }
}
