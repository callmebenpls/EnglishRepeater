import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testStatus: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("设定苹果耳机中键 单击/双击/三击 对应的动作。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } header: {
                    Text("耳机按键映射")
                }
                .listRowBackground(Theme.card)

                Section {
                    actionPicker(title: "单击中键", binding: $vm.keyMapping.singlePress)
                    actionPicker(title: "双击中键", binding: $vm.keyMapping.doublePress)
                    actionPicker(title: "三击中键", binding: $vm.keyMapping.triplePress)
                } footer: {
                    Text("适用于 AirPods 及有线耳机。AirPods 需在蓝牙设置中将双击/三击设为「下一首/上一首」。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.card)

                Section("当前映射预览") {
                    previewRow("单击", icon: "1.circle.fill", color: Theme.accent, action: vm.keyMapping.singlePress)
                    previewRow("双击", icon: "2.circle.fill", color: Theme.folderColors[1].fg, action: vm.keyMapping.doublePress)
                    previewRow("三击", icon: "3.circle.fill", color: Theme.green, action: vm.keyMapping.triplePress)
                }
                .listRowBackground(Theme.card)

                if Features.aiEnabled {
                    aiSection
                        .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func previewRow(_ label: String, icon: String, color: Color, action: ButtonAction) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading).foregroundStyle(Theme.textSecondary)
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(action.displayName).foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - AI Section

    private var aiSection: some View {
        Section {
            TextField("Base URL", text: configBinding(\.baseURL))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("API Key", text: configBinding(\.apiKey))
            TextField("模型", text: configBinding(\.model))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button(action: runTest) {
                HStack {
                    Text("测试连接").foregroundStyle(Theme.accent)
                    Spacer()
                    if testing {
                        ProgressView()
                    } else if let status = testStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(testOK ? Theme.green : .red)
                    }
                }
            }
            .disabled(testing)
        } header: {
            Text("AI 听力解析")
        } footer: {
            Text("把当前句的音频发给 AI,它会听并讲解(默认 OpenAI gpt-audio-mini)。把此动作映射到耳机按键,或用播放页的「AI 讲解」按钮触发。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func configBinding(_ keyPath: WritableKeyPath<AIConfig, String>) -> Binding<String> {
        Binding(
            get: { vm.aiExplainer.config[keyPath: keyPath] },
            set: { vm.aiExplainer.config[keyPath: keyPath] = $0 }
        )
    }

    private func runTest() {
        testing = true
        testStatus = nil
        vm.aiExplainer.testConnection { result in
            testing = false
            switch result {
            case .success:
                testOK = true
                testStatus = "连接成功 ✓"
            case .failure(let error):
                testOK = false
                testStatus = (error as? LocalizedError)?.errorDescription ?? "失败"
            }
        }
    }

    // MARK: - Picker Row
    private func actionPicker(title: String, binding: Binding<ButtonAction>) -> some View {
        let actions = ButtonAction.allCases.filter { action in
            if case .aiExplain = action { return Features.aiEnabled }   // hide AI mapping in v1
            return true
        }
        return Picker(title, selection: binding) {
            ForEach(actions, id: \.displayName) { action in
                Text(action.displayName).tag(action)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(PlayerViewModel())
}
