import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showLyricManager = false

    var body: some View {
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
        .navigationBarBackButtonHidden(true)        // hide "‹ 音频库" text
        .background(SwipeBackEnabler())             // keep right-swipe-to-go-back working
        .tint(Theme.accent)
        .toolbar {
            // Clean chevron back (no text). Swipe-right also works.
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
            }
            // Trailing group: lyrics manager + settings.
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if vm.isGeneratingSubtitles {
                    ProgressView().scaleEffect(0.8)
                } else if vm.currentItem != nil {
                    Button(action: { showLyricManager = true }) {
                        Image(systemName: vm.subtitleSource.hasLyrics ? "captions.bubble.fill" : "captions.bubble")
                    }
                }
                Button(action: { showSettings = true }) {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showLyricManager) {
            LyricManagerSheet()
                .environmentObject(vm)
                .presentationDetents([.medium, .large])
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "earbuds")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("还没有在播放")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("右滑回到音频库，选一段音频开始")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
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
                .onChange(of: vm.segments) { _ in centerActive(proxy) }   // new track
                .onAppear { centerActive(proxy) }                          // opening (e.g. paused)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Center the current line on open / track change, so a paused track shows its line
    /// centered (the per-tick scroll won't fire when paused). Delayed so the push transition
    /// and initial layout have settled — otherwise scrollTo is a no-op.
    private func centerActive(_ proxy: ScrollViewProxy) {
        let idx = nearestIndex
        guard idx >= 0 else { return }
        lastActive = idx
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            proxy.scrollTo(idx, anchor: .center)
        }
    }

    /// The line to center on: the active one, or — if the play head sits in a gap / before
    /// the first cue — the last line whose start has passed (so there's always a target).
    private var nearestIndex: Int {
        if !vm.segments.isEmpty {
            var idx = 0
            for (i, s) in vm.segments.enumerated() {
                if s.start <= t + 0.05 { idx = i } else { break }
            }
            return idx
        }
        let total = vm.displayText.components(separatedBy: .newlines).count
        return total > 0 ? activeLineIndex(total: total) : -1
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

// MARK: - Lyric Manager Sheet

/// Manage the lyric tracks for the current audio: pick which one is shown, delete, or add
/// (AI-generate / import .lrc). Auto-named tracks; LRC > AI priority when none is selected.
struct LyricManagerSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLRCImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                List {
                    if vm.lyricTracks.isEmpty {
                        Section {
                            Text("这条音频还没有字幕")
                                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        .listRowBackground(Theme.card)
                    } else {
                        Section("字幕") {
                            ForEach(vm.lyricTracks) { track in row(track) }
                        }
                        .listRowBackground(Theme.card)
                    }

                    Section {
                        Button {
                            if let item = vm.currentItem { vm.generateSubtitles(for: item) }
                            dismiss()
                        } label: {
                            Label(vm.lyricTracks.isEmpty ? "用 AI 生成字幕（本机离线，约 30–60 秒）" : "用 AI 生成",
                                  systemImage: "sparkles")
                                .foregroundStyle(Theme.accent)
                        }
                        Button { showLRCImporter = true } label: {
                            Label("导入 .lrc 文件", systemImage: "square.and.arrow.down")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("字幕")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $showLRCImporter,
                          allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .data]) { result in
                if case .success(let url) = result { vm.importLyricFile(url) }
            }
        }
    }

    private func row(_ track: LyricTrack) -> some View {
        Button { vm.selectLyric(track.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(track.kind)).foregroundStyle(Theme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(track.kind.tag + (track.hasTiming ? "" : " · 无时间轴"))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if track.id == vm.activeLyricID {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
        .listRowBackground(Theme.card)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { vm.deleteLyric(track.id) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func icon(_ kind: LyricTrack.Kind) -> String {
        switch kind {
        case .lrc: return "doc.text"
        case .recognized: return "waveform"
        case .plainText: return "text.alignleft"
        }
    }
}

// MARK: - Swipe-back enabler

/// Re-enables the interactive right-swipe-to-pop gesture when the default back button is
/// hidden (SwiftUI disables it otherwise). Harmless if the nav controller isn't found.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async {
            if let nav = vc.navigationController {
                nav.interactivePopGestureRecognizer?.isEnabled = true
                nav.interactivePopGestureRecognizer?.delegate = nil
            }
        }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
