import SwiftUI

/// First-launch walkthrough. Four swipeable screens that teach the non-obvious flow
/// (share-to-import, tap-a-line to loop, slowing down, earbud button mapping), then a
/// "Get started" button. Shown once, gated on the `hasSeenOnboarding_v1` flag owned by
/// the app root; this view just calls `onDone` when finished or skipped.
struct OnboardingView: View {
    let onDone: () -> Void

    @State private var page = 0
    private let pageCount = 4

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip — hidden on the last page, where "Get started" takes over.
                HStack {
                    Spacer()
                    if page < pageCount - 1 {
                        Button("跳过") { onDone() }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(height: 24)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    importPage.tag(1)
                    listenPage.tag(2)
                    handsFreePage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots
                    .padding(.top, 4)

                Button(action: advance) {
                    Text(page == pageCount - 1 ? "开始使用" : "下一步")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Theme.accentGradient))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .tint(Theme.accent)
    }

    private func advance() {
        if page < pageCount - 1 {
            withAnimation { page += 1 }
        } else {
            onDone()
        }
    }

    // MARK: - Page dots

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { i in
                Circle()
                    .fill(i == page ? Theme.accent : Theme.border)
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        pageScaffold(
            title: "通过精听，掌握英语",
            caption: "一次一句，把每个细节都听清。"
        ) {
            iconTile("headphones", size: 64, tile: 96)
        }
    }

    private var importPage: some View {
        pageScaffold(
            title: "添加你的音频",
            caption: "点击 + 导入，或在任意 App 里用「打开方式」分享过来。"
        ) {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    iconTile("plus", size: 30, tile: 60, solid: true)
                    iconTile("square.and.arrow.up", size: 26, tile: 60)
                }
                HStack(spacing: 10) {
                    Image(systemName: "music.note").foregroundStyle(Theme.accent)
                    Capsule().fill(Theme.chip).frame(height: 8)
                }
                .padding(12)
                .frame(width: 200)
                .warmCard()
            }
        }
    }

    private var listenPage: some View {
        pageScaffold(
            title: "用你的方式听",
            caption: "点按任意一句即可跳转并循环；放慢速度，听清每个词。"
        ) {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(verbatim: "…I had no idea")
                        .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    Text(verbatim: "what to do next")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(verbatim: "so I just waited")
                        .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: 8) {
                    miniPill { Label("循环", systemImage: "repeat") }
                    miniPill { Text(verbatim: "0.6×") }
                }
            }
        }
    }

    private var handsFreePage: some View {
        pageScaffold(
            title: "解放双手",
            caption: "把单击 / 双击 / 三击耳机按键，映射为播放、循环或跳转。"
        ) {
            VStack(spacing: 14) {
                iconTile("headphones", size: 30, tile: 56)
                HStack(spacing: 8) {
                    tapChip(n: "1×", action: "播放")
                    tapChip(n: "2×", action: "循环")
                    tapChip(n: "3×", action: "跳转")
                }
            }
        }
    }

    // MARK: - Building blocks

    /// Shared layout: a bespoke visual on top, then title + caption, vertically centered.
    private func pageScaffold<Visual: View>(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        VStack(spacing: 0) {
            Spacer()
            visual()
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .padding(.top, 32)
            Text(caption)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 12)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }

    private func iconTile(_ name: String, size: CGFloat, tile: CGFloat, solid: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: tile / 3.4, style: .continuous)
            .fill(solid ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accentSoft))
            .frame(width: tile, height: tile)
            .overlay(
                Image(systemName: name)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(solid ? .white : Theme.accent)
            )
    }

    private func miniPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.accentSoft))
    }

    private func tapChip(n: String, action: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: n).font(.system(size: 12, weight: .bold))
            Text(action).font(.system(size: 12))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.chip))
    }
}

#Preview {
    OnboardingView(onDone: {})
}
