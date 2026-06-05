import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("设定苹果耳机中键 单击/双击/三击 对应的动作。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("耳机按键映射")
                }

                Section {
                    actionPicker(title: "单击中键", binding: $vm.keyMapping.singlePress)
                    actionPicker(title: "双击中键", binding: $vm.keyMapping.doublePress)
                    actionPicker(title: "三击中键", binding: $vm.keyMapping.triplePress)
                } footer: {
                    Text("适用于 AirPods 及有线耳机。AirPods 需在蓝牙设置中将双击/三击设为「下一首/上一首」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("当前映射预览") {
                    HStack {
                        Text("单击")
                            .frame(width: 50, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Image(systemName: "1.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(vm.keyMapping.singlePress.displayName)
                    }
                    HStack {
                        Text("双击")
                            .frame(width: 50, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Image(systemName: "2.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(vm.keyMapping.doublePress.displayName)
                    }
                    HStack {
                        Text("三击")
                            .frame(width: 50, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Image(systemName: "3.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text(vm.keyMapping.triplePress.displayName)
                    }
                }
            }
            .navigationTitle("按键设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Picker Row
    private func actionPicker(title: String, binding: Binding<ButtonAction>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ButtonAction.allCases, id: \.displayName) { action in
                Text(action.displayName).tag(action)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(PlayerViewModel())
}
