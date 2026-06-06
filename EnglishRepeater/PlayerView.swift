import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.currentItem == nil {
                    emptyState
                } else {
                    contentView
                }
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.currentItem != nil && !vm.isGeneratingSubtitles {
                        Button(action: {
                            if let item = vm.currentItem {
                                vm.generateSubtitles(for: item)
                            }
                        }) {
                            Image(systemName: "captions.bubble")
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
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let item = vm.currentItem {
                    Text(item.dateAdded.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)

            lyricsSection

            progressSection

            controlsSection

            Spacer(minLength: 8)
        }
    }

    // MARK: - Lyrics

    private var lyricsSection: some View {
        VStack(spacing: 0) {
            // Subtitle generation progress
            if vm.isGeneratingSubtitles {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(vm.subtitleProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        vm.cancelSubtitleGeneration()
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if vm.displayText.isEmpty && !vm.isGeneratingSubtitles {
                        placeholderLyrics
                    } else {
                        actualLyrics
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: vm.currentTime) { _ in
                    if let activeIdx = activeSegmentIndex() {
                        withAnimation {
                            proxy.scrollTo(activeIdx, anchor: .center)
                        }
                    }
                }
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }

    private var placeholderLyrics: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray4))
                    .frame(height: 12)
                    .padding(.horizontal, 24)
                    .opacity(Double(6 - i) / 10.0)
            }
            Text("将同名 .txt 文件放在音频旁，内容将在此显示")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
            Spacer().frame(height: 40)
        }
        .padding(.vertical, 24)
    }

    private var actualLyrics: some View {
        if !vm.segments.isEmpty {
            return AnyView(segmentedLyrics)
        }
        let lines = vm.displayText.components(separatedBy: .newlines)
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    let isActive = lineIsActive(idx: idx, total: lines.count)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(isActive ? .primary : .tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isActive ? Color.blue.opacity(0.08) : Color.clear)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(width: 3)
                            }
                        }
                }
            }
            .padding(.vertical, 12)
        )
    }

    private var segmentedLyrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(vm.segments.enumerated()), id: \.offset) { idx, seg in
                let isActive = segmentIsActive(seg)
                Text(seg.text.isEmpty ? " " : seg.text)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(isActive ? .primary : .tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isActive ? Color.blue.opacity(0.08) : Color.clear)
                    .overlay(alignment: .leading) {
                        if isActive {
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 3)
                        }
                    }
            }
        }
        .padding(.vertical, 12)
    }

    private func segmentIsActive(_ seg: Segment) -> Bool {
        let t = vm.currentTime
        return t >= seg.start && t < seg.start + seg.duration
    }

    private func activeSegmentIndex() -> Int? {
        guard !vm.segments.isEmpty else { return nil }
        return vm.segments.firstIndex { segmentIsActive($0) }
    }

    private func lineIsActive(idx: Int, total: Int) -> Bool {
        guard total > 0, vm.duration > 0 else { return false }
        let fraction = vm.currentTime / vm.duration
        let activeIdx = Int(fraction * Double(total))
        return idx == activeIdx
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { vm.duration > 0 ? vm.currentTime / vm.duration : 0 },
                    set: { vm.seek(to: $0 * vm.duration) }
                )
            )
            .tint(.blue)

            HStack {
                Text(formatTime(vm.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(vm.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: 20) {
            Button(action: { vm.skip(by: -5) }) {
                HStack(spacing: 4) {
                    Image(systemName: "gobackward.5")
                    Text("5s")
                        .font(.caption)
                }
            }
            .disabled(vm.duration == 0)

            Button(action: { vm.togglePlay() }) {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
            }
            .disabled(vm.duration == 0)

            Button(action: { vm.skip(by: 5) }) {
                HStack(spacing: 4) {
                    Text("5s")
                        .font(.caption)
                    Image(systemName: "goforward.5")
                }
            }
            .disabled(vm.duration == 0)

            Button(action: { vm.toggleRepeatSentence() }) {
                Image(systemName: vm.loopingSegmentIndex != nil ? "repeat.1.circle.fill" : "repeat.1")
                    .foregroundStyle(vm.loopingSegmentIndex != nil ? .blue : .secondary)
            }
            .disabled(vm.duration == 0 || vm.segments.isEmpty)

            Button(action: { vm.aiExplain() }) {
                Image(systemName: vm.aiState == .idle ? "sparkles" : "sparkles.rectangle.stack.fill")
                    .foregroundStyle(vm.aiState == .idle ? Color.secondary : Color.blue)
            }
            .disabled(vm.duration == 0 || vm.segments.isEmpty)

            Rectangle()
                .fill(Color(.systemGray4))
                .frame(width: 0.5, height: 24)

            // Simple speed chip with -/+
            HStack(spacing: 0) {
                Button(action: { vm.setRate(vm.playbackRate - 0.05) }) {
                    Text("-")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 26)
                }

                Text(String(format: "%.2f", vm.playbackRate) + "x")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 36)

                Button(action: { vm.setRate(vm.playbackRate + 0.05) }) {
                    Text("+")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 26)
                }
            }
            .background(Color.blue)
            .clipShape(Capsule())
        }
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    PlayerView()
        .environmentObject(PlayerViewModel())
}

// MARK: - AI Explain Sheet

/// Shown while the AI listens and explains the current sentence. Purely visual — the
/// audio experience (slow-loop while waiting, then the spoken explanation) is driven by
/// the view model and works with the screen locked.
struct AIExplainSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI 听力解析", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
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
        .presentationDragIndicator(.visible)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                Text("AI 正在听这一句…")
                    .foregroundStyle(.secondary)
            }
            Text("正在以 0.6× 慢速循环这一句,你可以先自己听听看。AI 一回复就会念给你听。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(role: .cancel) { vm.cancelAI() } label: {
                Text("取消").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }

    private func speaking(text: String, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: pending ? "hourglass" : "speaker.wave.2.fill")
                    .foregroundStyle(.blue)
                Text(pending ? "即将播放讲解…" : "正在讲解")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text.isEmpty ? "（语音讲解中）" : text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            HStack {
                Button { vm.aiExplain() } label: {
                    Text("重试").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .cancel) { dismiss() } label: {
                    Text("关闭").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
