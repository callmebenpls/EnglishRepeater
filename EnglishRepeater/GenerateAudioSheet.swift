import SwiftUI
import AVFoundation

/// The AI audio generation flow: options → script review (with learning pack) → synthesis.
/// One generation at a time; everything goes through the OpenAI-compatible AIConfig.
struct GenerateAudioSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case options
        case scripting
        case review
        case synthesizing(done: Int, total: Int)
    }

    @State private var phase: Phase = .options
    @State private var options = GenerationOptions()
    @State private var pack: GeneratedPack?
    @State private var errorMessage: String?
    @State private var pickingVoiceForB = false
    @State private var showVoicePicker = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                switch phase {
                case .options: optionsForm
                case .scripting: progressPane(String(localized: "正在生成脚本…"))
                case .review: reviewPane
                case .synthesizing(let done, let total):
                    progressPane(String(localized: "正在合成语音…") + " \(done)/\(total)")
                }
            }
            .navigationTitle("AI 生成音频")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert(String(localized: "生成失败"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("关闭", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $showVoicePicker) {
                VoicePickerSheet(selected: pickingVoiceForB ? $options.voiceB : $options.voiceA,
                                 generator: AudioGenerator(config: vm.aiExplainer.config))
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(vm) }
        }
        .interactiveDismissDisabled(phase != .options)
    }

    // MARK: - Options

    private var optionsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !vm.aiExplainer.isConfigured {
                    Button { showSettings = true } label: {
                        Label(String(localized: "请先在设置里填入 AI 接口和密钥"), systemImage: "gearshape")
                            .font(.footnote).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).warmCard()
                    }
                }

                TextField(String(localized: "想听什么？描述场景或主题…"), text: $options.prompt, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12).warmCard()

                chipRow(["日常闲聊", "美剧风对话", "旅行", "职场"].map { String(localized: String.LocalizationValue($0)) }) { preset in
                    options.prompt = preset
                }

                section(String(localized: "口语程度")) {
                    pickerChips([String(localized: "教科书"), String(localized: "自然口语"), String(localized: "俚语拉满")],
                                selection: $options.register)
                }

                section(String(localized: "时长")) {
                    HStack(spacing: 6) {
                        ForEach([1, 2, 3, 5], id: \.self) { m in
                            chip("\(m) " + String(localized: "分钟"), on: options.minutes == m) { options.minutes = m }
                        }
                    }
                }

                section(String(localized: "语言点 · 想练什么（可多选）")) {
                    HStack(spacing: 6) {
                        ForEach(LangPointCategory.allCases, id: \.self) { cat in
                            chip(cat.label, on: options.categories.contains(cat)) {
                                if options.categories.contains(cat) {
                                    if options.categories.count > 1 { options.categories.remove(cat) }
                                } else { options.categories.insert(cat) }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text("密度").font(.caption2).foregroundStyle(Theme.textTertiary)
                        pickerChips([String(localized: "少"), String(localized: "中"), String(localized: "多")],
                                    selection: $options.density)
                        Text("≈ \(options.targetPointCount) 个").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }

                section(String(localized: "难度")) {
                    HStack(spacing: 6) {
                        ForEach(["A2", "B1", "B2", "C1"], id: \.self) { l in
                            chip(l, on: options.level == l) { options.level = l }
                        }
                    }
                }

                section(String(localized: "形式") + " · " + String(localized: "语速")) {
                    HStack(spacing: 6) {
                        chip(String(localized: "对话 · 双声"), on: options.dialogue) { options.dialogue = true }
                        chip(String(localized: "独白"), on: !options.dialogue) { options.dialogue = false }
                        chip(String(localized: "自然语速"), on: !options.slowPace) { options.slowPace = false }
                        chip(String(localized: "偏慢"), on: options.slowPace) { options.slowPace = true }
                    }
                }

                section(String(localized: "声音")) {
                    VStack(spacing: 0) {
                        voiceRow(String(localized: "角色 A"), voice: options.voiceA) {
                            pickingVoiceForB = false; showVoicePicker = true
                        }
                        if options.dialogue {
                            Divider().padding(.leading, 12)
                            voiceRow(String(localized: "角色 B"), voice: options.voiceB) {
                                pickingVoiceForB = true; showVoicePicker = true
                            }
                        }
                    }
                    .warmCard()
                }

                Button(action: startScript) {
                    Label(String(localized: "生成脚本"), systemImage: "sparkles")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentGradient))
                }
                .disabled(!vm.aiExplainer.isConfigured)
                .opacity(vm.aiExplainer.isConfigured ? 1 : 0.5)
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private func voiceRow(_ label: String, voice: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(voice.capitalized).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    // MARK: - Review

    private var reviewPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let pack {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(pack.title)
                            .font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)

                        deliveredChips(pack)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(pack.lines.enumerated()), id: \.offset) { _, line in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(alignment: .top, spacing: 5) {
                                        if !line.speaker.isEmpty {
                                            Text(line.speaker + ":").font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                        Text(line.en).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                                    }
                                    Text(line.zh).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                        .padding(.leading, line.speaker.isEmpty ? 0 : 18)
                                }
                            }
                        }
                        .padding(12).warmCard()

                        NotesPackView(pack: pack)
                    }
                    .padding(16)
                }
            }

            HStack(spacing: 10) {
                Button(action: startScript) {
                    Label(String(localized: "重新生成"), systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(12)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.chip))
                }
                Button(action: startSynthesis) {
                    Label(String(localized: "生成音频"), systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(12)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.accentGradient))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func deliveredChips(_ pack: GeneratedPack) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(options.categories).sorted { $0.rawValue < $1.rawValue }, id: \.self) { cat in
                let got = pack.points.filter { $0.category == cat }.count
                Text("\(cat.label) \(got)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(got > 0 ? Theme.green : Theme.textTertiary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(got > 0 ? Theme.greenBg : Theme.chip))
            }
            Spacer()
        }
    }

    // MARK: - Progress

    private func progressPane(_ label: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.3).tint(Theme.accent)
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Actions

    private func startScript() {
        phase = .scripting
        let generator = AudioGenerator(config: vm.aiExplainer.config)
        let opts = options
        Task {
            do {
                let result = try await generator.generateScript(options: opts)
                await MainActor.run { pack = result; phase = .review }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    phase = pack == nil ? .options : .review
                }
            }
        }
    }

    private func startSynthesis() {
        guard let pack else { return }
        phase = .synthesizing(done: 0, total: pack.lines.count)
        let generator = AudioGenerator(config: vm.aiExplainer.config)
        let opts = options
        Task {
            do {
                let (url, segments) = try await generator.synthesizeAll(pack: pack, options: opts) { done, total in
                    phase = .synthesizing(done: done, total: total)
                }
                await MainActor.run {
                    vm.addGeneratedAudio(fileURL: url, pack: pack, segments: segments)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    phase = .review
                }
            }
        }
    }

    // MARK: - Small pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.accentSoft : Theme.chip))
        }
    }

    private func pickerChips(_ labels: [String], selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                chip(label, on: selection.wrappedValue == i) { selection.wrappedValue = i }
            }
        }
    }

    private func chipRow(_ labels: [String], action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                chip(label, on: false) { action(label) }
            }
        }
    }
}

// MARK: - Voice picker

struct VoicePickerSheet: View {
    @Binding var selected: String
    let generator: AudioGenerator
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var loadingVoice: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                List {
                    ForEach(VoiceInfo.all) { voice in
                        HStack(spacing: 10) {
                            Button { selected = voice.id; dismiss() } label: {
                                HStack {
                                    Text(voice.id.capitalized)
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                    Text(voice.descriptionKey)
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    if selected == voice.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            Button { preview(voice.id) } label: {
                                if loadingVoice == voice.id {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 22)).foregroundStyle(Theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("声音")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func preview(_ voice: String) {
        loadingVoice = voice
        Task {
            defer { Task { @MainActor in loadingVoice = nil } }
            guard let url = try? await generator.previewSample(voice: voice) else { return }
            await MainActor.run {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.play()
            }
        }
    }
}

// MARK: - Learning pack rendering (shared: review step + player notes sheet)

struct NotesPackView: View {
    let pack: GeneratedPack
    private let speech = AVSpeechSynthesizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !pack.points.isEmpty {
                Text("语言点").font(.caption2).foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pack.points) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(p.phrase).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                Text(p.category.label).font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.accentSoft))
                                Spacer()
                                speakButton(p.phrase)
                            }
                            Text(p.explanation).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accentSoft.opacity(0.35)))
                    }
                }
            }

            if !pack.vocab.isEmpty {
                Text("词汇").font(.caption2).foregroundStyle(Theme.textTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(pack.vocab) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.word).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                Text("\(v.pos) \(v.zh)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            speakButton(v.word)
                        }
                        .padding(10).warmCard(radius: 11)
                    }
                }
            }

            if !pack.expressions.isEmpty {
                Text("表达").font(.caption2).foregroundStyle(Theme.textTertiary)
                VStack(spacing: 0) {
                    ForEach(Array(pack.expressions.enumerated()), id: \.offset) { i, e in
                        if i > 0 { Divider().padding(.leading, 12) }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.phrase).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                Text(e.zh).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            speakButton(e.phrase)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .warmCard()
            }
        }
    }

    private func speakButton(_ text: String) -> some View {
        Button {
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
            u.rate = 0.45
            speech.speak(u)
        } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

/// Read-only learning notes, reopened from the player's 📖 button.
struct NotesSheet: View {
    let pack: GeneratedPack
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                ScrollView {
                    NotesPackView(pack: pack).padding(16)
                }
            }
            .navigationTitle("学习笔记")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
