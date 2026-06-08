import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @State private var showSettings = false
    @State private var showSubtitleOptions = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    if vm.currentItem == nil {
                        emptyState
                    } else {
                        contentView
                    }
                }
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.currentItem != nil && !vm.isGeneratingSubtitles {
                        Button(action: {
                            guard let item = vm.currentItem else { return }
                            if vm.subtitleSource.hasLyrics {
                                showSubtitleOptions = true        // already have lyrics → ask first
                            } else {
                                vm.generateSubtitles(for: item)   // nothing to lose → generate
                            }
                        }) {
                            Image(systemName: vm.subtitleSource.hasLyrics ? "captions.bubble.fill" : "captions.bubble")
                        }
                    }
                    if vm.isGeneratingSubtitles {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(vm)
            }
            .confirmationDialog(
                "当前：\(vm.subtitleSource.label)",
                isPresented: $showSubtitleOptions,
                titleVisibility: .visible
            ) {
                if let item = vm.currentItem {
                    Button("重新识别（替换现有字幕）", role: .destructive) {
                        vm.regenerateSubtitles(for: item)
                    }
                    Button("清除字幕", role: .destructive) {
                        vm.clearSubtitles(for: item)
                    }
                    Button("取消", role: .cancel) {}
                }
            } message: {
                Text("这条音频已有字幕。重新识别或清除都会覆盖现有字幕，无法恢复。")
            }
            .sheet(isPresented: Binding(
                get: { vm.aiState != .idle },
                set: { if !$0 { vm.cancelAI() } }
            )) {
                AIExplainSheet()
                    .environmentObject(vm)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "earbuds")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("从音频库选择音频")
                .font(.headline)
            Text("切换到\"音频库\"标签页导入并选择音频")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(vm.currentFileName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("英语精听")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Time-dependent UI lives in its own observer of the clock, so the 0.25s
            // ticks only re-render here — not the whole Player or the Library.
            PlaybackPane(vm: vm, clock: vm.clock)
                .frame(maxHeight: .infinity)

            controlsSection
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 18) {
            // Tier 1 — primary transport
            HStack(spacing: 36) {
                Button(action: { vm.skip(by: -5) }) {
                    VStack(spacing: 2) {
                        Image(systemName: "gobackward.5").font(.system(size: 22))
                        Text("5s").font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .disabled(vm.duration == 0)

                Button(action: { vm.togglePlay() }) {
                    ZStack {
                        Circle().fill(Theme.accentGradient).frame(width: 74, height: 74)
                            .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 6)
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28)).foregroundStyle(.white)
                            .offset(x: vm.isPlaying ? 0 : 2)
                    }
                }
                .disabled(vm.duration == 0)

                Button(action: { vm.skip(by: 5) }) {
                    VStack(spacing: 2) {
                        Image(systemName: "goforward.5").font(.system(size: 22))
                        Text("5s").font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .disabled(vm.duration == 0)
            }

            // Tier 2 — secondary pills
            HStack(spacing: 10) {
                pill(icon: "repeat.1", label: "循环",
                     on: vm.isLooping,
                     disabled: vm.duration == 0) { vm.toggleRepeatSentence() }
                pill(icon: "sparkles", label: "AI 讲解",
                     on: vm.aiState != .idle,
                     disabled: vm.duration == 0) { vm.aiExplain() }
                speedPill
            }
        }
        .padding(.vertical, 14)
    }

    private func pill(icon: String, label: String, on: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(on ? Theme.accentSoft : Theme.chip))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var speedPill: some View {
        HStack(spacing: 0) {
            Button { vm.setRate(vm.playbackRate - 0.05) } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 26, height: 32)
            }
            Text(String(format: "%.2f×", vm.playbackRate))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary).frame(minWidth: 44)
            Button { vm.setRate(vm.playbackRate + 0.05) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 26, height: 32)
            }
        }
        .background(Capsule().fill(Theme.chip))
    }

}

#Preview {
    PlayerView()
        .environmentObject(PlayerViewModel())
}

// MARK: - Playback Pane (lyrics + progress, clock-observing)

/// Owns everything that depends on the playback position. It observes `PlaybackClock`
/// (which ticks 4×/second) so only this subtree re-renders on each tick — the surrounding
/// Player chrome and the Library never see the clock. The karaoke scroll is gated on the
/// active line *changing*, not on every tick.
private struct PlaybackPane: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    @State private var lastActive = -1

    private var t: TimeInterval { clock.currentTime }

    var body: some View {
        VStack(spacing: 0) {
            lyrics
                .frame(maxHeight: .infinity)
            progress
        }
    }

    // MARK: Lyrics

    private var lyrics: some View {
        VStack(spacing: 0) {
            if vm.isGeneratingSubtitles {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.subtitleProgress).font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("取消") { vm.cancelSubtitleGeneration() }
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 20).padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    if vm.displayText.isEmpty && !vm.isGeneratingSubtitles {
                        placeholderLyrics
                    } else {
                        actualLyrics
                    }
                }
                .frame(maxHeight: .infinity)
                .onChange(of: activeIndex) { idx in
                    // Only scroll when the active line actually changes (not every tick).
                    guard idx >= 0, idx != lastActive else { return }
                    lastActive = idx
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var placeholderLyrics: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3).fill(Theme.border)
                    .frame(height: 12).padding(.horizontal, 24).opacity(Double(6 - i) / 10.0)
            }
            Text("点左上角生成字幕，或导入同名 .lrc 字幕")
                .font(.caption).foregroundStyle(Theme.textSecondary).padding(.top, 16)
            Spacer().frame(height: 40)
        }
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var actualLyrics: some View {
        if !vm.segments.isEmpty {
            let active = activeIndex
            VStack(spacing: 18) {
                Spacer().frame(height: 60)
                ForEach(Array(vm.segments.enumerated()), id: \.offset) { idx, seg in
                    karaokeLine(seg.text, distance: abs(idx - active), active: idx == active)
                        .id(idx)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.clearLoopIfActive()   // deliberate seek cancels the 5s loop
                            vm.seek(to: seg.start)
                            if !vm.isPlaying { vm.play() }
                        }
                }
                Spacer().frame(height: 60)
            }
            .padding(.horizontal, 12)
        } else {
            let lines = vm.displayText.components(separatedBy: .newlines)
            let active = lines.isEmpty ? 0 : activeLineIndex(total: lines.count)
            VStack(spacing: 18) {
                Spacer().frame(height: 60)
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    karaokeLine(line, distance: abs(idx - active), active: idx == active)
                        .id(idx)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard vm.duration > 0, !lines.isEmpty else { return }
                            vm.clearLoopIfActive()
                            vm.seek(to: vm.duration * Double(idx) / Double(lines.count))
                            if !vm.isPlaying { vm.play() }
                        }
                }
                Spacer().frame(height: 60)
            }
            .padding(.horizontal, 12)
        }
    }

    private func karaokeLine(_ text: String, distance: Int, active: Bool) -> some View {
        let opacity: Double = active ? 1.0 : max(0.18, 0.6 - Double(distance) * 0.16)
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: active ? 25 : 17, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
            .opacity(opacity)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: active)
    }

    /// Active line index for segmented OR plain-text lyrics (segments take priority).
    private var activeIndex: Int {
        if !vm.segments.isEmpty {
            return vm.segments.firstIndex { t >= $0.start && t < $0.start + $0.duration } ?? -1
        }
        let total = vm.displayText.components(separatedBy: .newlines).count
        return activeLineIndex(total: total)
    }

    private func activeLineIndex(total: Int) -> Int {
        guard total > 0, vm.duration > 0 else { return 0 }
        return min(total - 1, max(0, Int(t / vm.duration * Double(total))))
    }

    // MARK: Progress

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { vm.duration > 0 ? t / vm.duration : 0 },
                set: { vm.seek(to: $0 * vm.duration) }
            ))
            .tint(Theme.accent)

            HStack {
                Text(formatTime(t)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(formatTime(vm.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - AI Explain Sheet

/// Shown while the AI listens and explains the current sentence. Purely visual — the
/// audio experience (slow-loop while waiting, then the spoken explanation) is driven by
/// the view model and works with the screen locked.
struct AIExplainSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("AI 听力解析", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                switch vm.aiState {
                case .preparing, .waiting:
                    waiting
                case .speaking(let text, let pending):
                    speaking(text: text, pending: pending)
                case .error(let message):
                    errorView(message)
                case .idle:
                    EmptyView()
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDragIndicator(.visible)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("AI 正在听这一句…")
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("正在以 0.6× 慢速循环这一句,你可以先自己听听看。AI 一回复就会念给你听。")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Button { vm.cancelAI() } label: {
                Text("取消").frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(Theme.textSecondary)
                    .background(Capsule().fill(Theme.chip))
            }
            .padding(.top, 4)
        }
    }

    private func speaking(text: String, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: pending ? "hourglass" : "speaker.wave.2.fill")
                    .foregroundStyle(Theme.accent)
                Text(pending ? "即将播放讲解…" : "循环播放中 · 关闭即停止")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                Text(text.isEmpty ? "（语音讲解中）" : text)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            HStack(spacing: 10) {
                Button { vm.aiExplain() } label: {
                    Text("重试").frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentGradient))
                }
                Button { dismiss() } label: {
                    Text("关闭").frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip))
                }
            }
        }
    }
}
