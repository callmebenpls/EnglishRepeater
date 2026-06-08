import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Binding var page: Int

    @State private var showFilePicker = false
    @State private var searchText = ""
    @State private var expanded: Set<String> = []          // folder keys that are open
    @State private var initializedExpansion = false

    // Import review
    @State private var pendingImport: ImportPlan?

    // Move / folder management
    @State private var movingItem: LibraryItem?
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: Folder?
    @State private var renameText = ""
    @State private var deleteTarget: Folder?
    @State private var folderActions: Folder?      // long-pressed folder → action sheet

    @State private var toast: String?

    private let unsortedKey = "unsorted"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    StatsCardContainer(stats: vm.stats)
                    if vm.library.isEmpty && vm.folders.isEmpty {
                        emptyState
                    } else if !searchText.isEmpty {
                        searchResults
                    } else {
                        folderList
                    }
                }

                if let toast { toastView(toast) }
            }
            // Swipe in from the RIGHT edge → go to the Player (mirror of the back gesture).
            // Edge-only so it doesn't clash with rows' swipe-to-delete/move.
            .background(RightEdgePushGesture {
                if vm.currentItem != nil { page = 1 }
            })
            .navigationTitle("音频库")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: Binding(
                get: { page == 1 && vm.currentItem != nil },
                set: { if !$0 { page = 0 } }
            )) {
                PlayerView()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showFilePicker = true } label: { Label("导入音频", systemImage: "square.and.arrow.down") }
                        Button { startNewFolder() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .tint(Theme.accent)
            .searchable(text: $searchText, prompt: "搜索音频...")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio, UTType(filenameExtension: "lrc") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { handlePicked(urls) }
            }
            .sheet(item: $pendingImport) { plan in
                ImportReviewSheet(plan: plan) { folderID in
                    let n = vm.commitImport(plan, toFolder: folderID)
                    let where_ = folderID.flatMap { id in vm.folders.first { $0.id == id }?.name } ?? "未分类"
                    showToast("已导入 \(n) 个到 \(where_)")
                    if folderID != nil { expanded.insert(folderID!.uuidString) } else { expanded.insert(unsortedKey) }
                }
                .environmentObject(vm)
            }
            .sheet(item: $movingItem) { item in
                MoveToFolderSheet(item: item) { folderID in
                    vm.moveItem(item, toFolder: folderID)
                    showToast("已移动")
                }
                .environmentObject(vm)
            }
            .alert("新建文件夹", isPresented: $newFolderPresented) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let f = vm.createFolder(name: newFolderName)
                    expanded.insert(f.id.uuidString)
                }
            }
            .alert("重命名文件夹", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let t = renameTarget { vm.renameFolder(t, to: renameText) }
                    renameTarget = nil
                }
            }
            .alert("删除文件夹？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { folder in
                Button("删除文件夹及其音频", role: .destructive) { vm.deleteFolder(folder); deleteTarget = nil }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: { folder in
                Text("「\(folder.name)」及其中 \(vm.items(in: folder.id).count) 个音频都会被删除,无法恢复。")
            }
            .confirmationDialog(folderActions?.name ?? "", isPresented: Binding(
                get: { folderActions != nil }, set: { if !$0 { folderActions = nil } }),
                titleVisibility: .visible, presenting: folderActions) { folder in
                Button("重命名") { startRename(folder) }
                Button("删除文件夹", role: .destructive) { deleteTarget = folder }
                Button("取消", role: .cancel) {}
            }
            .onAppear(perform: initExpansionOnce)
        }
    }

    // MARK: - Picked files → review

    private func handlePicked(_ urls: [URL]) {
        let plan = vm.prepareImport(urls: urls)
        if plan.candidates.isEmpty {
            showToast(urls.isEmpty ? "未选择文件" : "没有可导入的音频")
        } else {
            pendingImport = plan
        }
    }

    // MARK: - Folder list

    private var sortedFolders: [Folder] { vm.folders.sorted { $0.order < $1.order } }

    private var folderList: some View {
        List {
            ForEach(sortedFolders) { folder in
                folderSection(folder)
            }
            unsortedSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func folderSection(_ folder: Folder) -> some View {
        let items = vm.items(in: folder.id)
        Section {
            if expanded.contains(folder.id.uuidString) {
                ForEach(items) { item in itemRow(item) }
                if items.isEmpty {
                    Text("空文件夹 · 从其他音频「移到」这里")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.card)
                }
            }
        } header: {
            folderHeader(folder, count: items.count, progress: aggregateProgress(items))
        }
    }

    @ViewBuilder
    private var unsortedSection: some View {
        let items = vm.items(in: nil)
        Section {
            if expanded.contains(unsortedKey) {
                ForEach(items) { item in itemRow(item) }
            }
        } header: {
            Button { toggle(unsortedKey) } label: {
                HStack(spacing: 12) {
                    folderTile(color: Theme.folderColors.last!, icon: "tray")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未分类").font(.system(size: 15.5, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Text("\(items.count) 个 · 新导入的会放这里").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    chevron(expanded.contains(unsortedKey))
                }
            }
            .textCase(nil)
            .padding(.vertical, 2)
        }
    }

    private func folderHeader(_ folder: Folder, count: Int, progress: Double) -> some View {
        HStack(spacing: 12) {
            folderTile(color: Theme.folderColors[folder.colorIndex % Theme.folderColors.count],
                       icon: Theme.folderIcons[folder.iconIndex % Theme.folderIcons.count])
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.system(size: 15.5, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("\(count) 个 · 长按重命名").font(.caption2).foregroundStyle(Theme.textSecondary)
                if progress > 0 {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .frame(width: 120)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                }
            }
            Spacer()
            chevron(expanded.contains(folder.id.uuidString))
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggle(folder.id.uuidString) }
        .onLongPressGesture { folderActions = folder }
    }

    // MARK: - Item row

    private func itemRow(_ item: LibraryItem) -> some View {
        let isCurrent = vm.currentItem?.id == item.id
        return Button {
            if isCurrent {
                page = 1                 // already playing — just go to the Player, no restart
            } else {
                vm.selectItem(item)
                withAnimation { page = 1 }
            }
        } label: {
            HStack(spacing: 12) {
                progressAvatar(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                    Text(isCurrent ? "正在播放 · \(progressLabel(item))" : progressLabel(item))
                        .font(.caption2)
                        .foregroundStyle(isCurrent ? Theme.accent.opacity(0.8) : Theme.textSecondary)
                }
                Spacer()
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
        }
        .listRowBackground(isCurrent ? Theme.accentSoft.opacity(0.5) : Theme.card)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { vm.removeItem(item) } label: { Label("删除", systemImage: "trash") }
            Button { movingItem = item } label: { Label("移到", systemImage: "folder") }
                .tint(Theme.accent)
        }
    }

    // MARK: - Search (flat)

    private var searchResults: some View {
        let items = vm.library.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
        return List {
            ForEach(items) { item in itemRow(item) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
    }

    // MARK: - Small pieces

    private func folderTile(color: (bg: Color, fg: Color), icon: String) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(color.bg)
            .frame(width: 40, height: 40)
            .overlay(Image(systemName: icon).font(.system(size: 17)).foregroundStyle(color.fg))
    }

    private func chevron(_ open: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(open ? 90 : 0))
    }

    private func progressAvatar(_ item: LibraryItem) -> some View {
        let f = item.progressFraction
        return ZStack {
            if f > 0.001 && f < 0.999 {
                Circle().stroke(Theme.border, lineWidth: 3).frame(width: 34, height: 34)
                Circle().trim(from: 0, to: f)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 34, height: 34)
                Text("\(Int(f * 100))").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
            } else if f >= 0.999 {
                Circle().fill(Theme.greenBg).frame(width: 34, height: 34)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.green)
            } else {
                Circle().fill(Theme.chip).frame(width: 34, height: 34)
                Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func progressLabel(_ item: LibraryItem) -> String {
        func fmt(_ t: TimeInterval) -> String {
            guard t.isFinite, t >= 0 else { return "0:00" }
            return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
        }
        if item.duration > 0 { return "\(fmt(item.progress)) / \(fmt(item.duration))" }
        return "未播放"
    }

    private func aggregateProgress(_ items: [LibraryItem]) -> Double {
        let withDur = items.filter { $0.duration > 0 }
        guard !withDur.isEmpty else { return 0 }
        return withDur.map { $0.progressFraction }.reduce(0, +) / Double(withDur.count)
    }

    // MARK: - Actions

    private func toggle(_ key: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }
    }

    private func initExpansionOnce() {
        guard !initializedExpansion else { return }
        initializedExpansion = true
        // Open everything by default so nothing feels hidden on first run.
        expanded = Set(vm.folders.map { $0.id.uuidString } + [unsortedKey])
    }

    private func startNewFolder() {
        newFolderName = ""
        newFolderPresented = true
    }

    private func startRename(_ folder: Folder) {
        renameText = folder.name
        renameTarget = folder
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { if toast == message { toast = nil } }
        }
    }

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
            Text(message).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Capsule().fill(Theme.textPrimary))
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 48)).foregroundStyle(Theme.accent.opacity(0.5))
            Text("还没有音频").font(.headline).foregroundStyle(Theme.textPrimary)
            Text("点击右上角 + 导入音频，或从其他 App 用「打开方式」分享").font(.subheadline)
                .foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
        }
    }
}

#Preview {
    LibraryView(page: .constant(0))
        .environmentObject(PlayerViewModel())
}

// MARK: - Stats Card (warm)

private struct StatsCardContainer: View {
    @ObservedObject var stats: ListeningStats
    var body: some View {
        StatsCard(todayMinutes: stats.todayMinutes, totalMinutes: stats.totalMinutes)
    }
}

private struct StatsCard: View {
    let todayMinutes: Int
    let totalMinutes: Int

    var body: some View {
        HStack(spacing: 0) {
            column(label: "TODAY", value: todayMinutes, dim: todayMinutes == 0)
            Text("·").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Theme.accentSoft).padding(.bottom, 18)
            column(label: "TOTAL", value: totalMinutes, dim: false)
        }
        .padding(.vertical, 18).padding(.horizontal, 16)
        .warmCard()
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    private func column(label: String, value: Int, dim: Bool) -> some View {
        VStack(spacing: 5) {
            Text(label).font(.caption2).tracking(1.4).foregroundStyle(Theme.textTertiary)
            Text("\(value)").font(.system(size: 48, weight: .thin, design: .rounded))
                .monospacedDigit().foregroundStyle(Theme.textPrimary).opacity(dim ? 0.28 : 1)
            Text("min").font(.caption).foregroundStyle(Theme.textTertiary).opacity(dim ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Import Review Sheet

struct ImportReviewSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    let plan: ImportPlan
    let onCommit: (UUID?) -> Void

    @State private var destination: UUID?          // nil = 未分类
    @State private var newFolderPresented = false
    @State private var newFolderName = ""

    private var destinationName: String {
        destination.flatMap { id in vm.folders.first { $0.id == id }?.name } ?? "未分类"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    destinationPicker
                    List {
                        let news = plan.newCandidates
                        if !news.isEmpty {
                            Section("将导入 · \(news.count) 个音频") {
                                ForEach(news) { c in candidateRow(c, dup: false) }
                            }
                        }
                        let dups = plan.candidates.filter { $0.isDuplicate }
                        if !dups.isEmpty {
                            Section("已跳过 · \(dups.count) 个") {
                                ForEach(dups) { c in candidateRow(c, dup: true) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)

                    commitButton
                }
            }
            .navigationTitle("导入音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .tint(Theme.accent)
            .alert("新建文件夹", isPresented: $newFolderPresented) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") { destination = vm.createFolder(name: newFolderName).id }
            }
        }
    }

    private var destinationPicker: some View {
        Menu {
            Button { destination = nil } label: { Label("未分类", systemImage: "tray") }
            ForEach(vm.folders.sorted { $0.order < $1.order }) { f in
                Button { destination = f.id } label: { Label(f.name, systemImage: Theme.folderIcons[f.iconIndex % Theme.folderIcons.count]) }
            }
            Divider()
            Button { newFolderName = ""; newFolderPresented = true } label: { Label("新建文件夹…", systemImage: "folder.badge.plus") }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accentSoft)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "folder").foregroundStyle(Theme.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("放到文件夹").font(.caption2).foregroundStyle(Theme.textTertiary)
                    Text(destinationName).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .warmCard()
            .padding(.horizontal, 16).padding(.top, 12)
        }
    }

    private func candidateRow(_ c: ImportCandidate, dup: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 50).fill(dup ? Theme.border : Theme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "music.note").foregroundStyle(dup ? Theme.textTertiary : Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayTitle).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if dup {
                    Label("已在库中", systemImage: "xmark.circle").font(.caption2).foregroundStyle(Theme.textTertiary)
                } else if c.hasSubtitle {
                    Label("已配字幕", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(Theme.green)
                } else {
                    Label("无字幕 · 可稍后生成", systemImage: "circle").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if let bytes = c.sizeBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .opacity(dup ? 0.55 : 1)
        .listRowBackground(Theme.card)
    }

    private var commitButton: some View {
        VStack(spacing: 8) {
            Button {
                onCommit(destination)
                dismiss()
            } label: {
                Text(plan.newCount > 0 ? "导入 \(plan.newCount) 个音频" : "没有可导入的音频")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(15)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accentGradient))
            }
            .disabled(plan.newCount == 0)
            .opacity(plan.newCount == 0 ? 0.5 : 1)

            if plan.withSubtitleCount > 0 || plan.duplicateCount > 0 {
                Text(subline).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private var subline: String {
        var parts: [String] = []
        if plan.withSubtitleCount > 0 { parts.append("\(plan.withSubtitleCount) 个含字幕") }
        if plan.duplicateCount > 0 { parts.append("\(plan.duplicateCount) 个重复已跳过") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Move To Folder Sheet

struct MoveToFolderSheet: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let onPick: (UUID?) -> Void

    @State private var newFolderPresented = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                List {
                    Section {
                        row(name: "未分类", icon: "tray", color: Theme.folderColors.last!,
                            selected: item.folderID == nil) { pick(nil) }
                        ForEach(vm.folders.sorted { $0.order < $1.order }) { f in
                            row(name: f.name, icon: Theme.folderIcons[f.iconIndex % Theme.folderIcons.count],
                                color: Theme.folderColors[f.colorIndex % Theme.folderColors.count],
                                selected: item.folderID == f.id) { pick(f.id) }
                        }
                    }
                    Section {
                        Button { newFolderName = ""; newFolderPresented = true } label: {
                            Label("新建文件夹…", systemImage: "folder.badge.plus").foregroundStyle(Theme.accent)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("移到文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .tint(Theme.accent)
            .alert("新建文件夹", isPresented: $newFolderPresented) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建并移入") { pick(vm.createFolder(name: newFolderName).id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ id: UUID?) { onPick(id); dismiss() }

    private func row(name: String, icon: String, color: (bg: Color, fg: Color),
                     selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.bg)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color.fg))
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .listRowBackground(Theme.card)
    }
}

// MARK: - Right-edge push gesture

/// A leftward swipe that begins near the RIGHT edge fires `action` — used to swipe into the
/// Player. Uses a plain pan (not the narrow ~20pt system edge recognizer) with a wider
/// ~64pt start zone and a low threshold, so it's much more sensitive. Still edge-anchored,
/// so it won't clash with the rows' mid-screen swipe-to-delete/move. Attached to the window.
private struct RightEdgePushGesture: UIViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, context.coordinator.gesture == nil else { return }
            let g = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handle(_:)))
            g.delegate = context.coordinator
            window.addGestureRecognizer(g)
            context.coordinator.gesture = g
            context.coordinator.window = window
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        weak var gesture: UIPanGestureRecognizer?
        weak var window: UIWindow?
        private var fired = false
        init(action: @escaping () -> Void) { self.action = action }

        // Only start when the touch begins within ~64pt of the right edge and moves left.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let window, let pan = g as? UIPanGestureRecognizer else { return false }
            let start = pan.location(in: window)
            guard start.x > window.bounds.width - 64 else { return false }
            let v = pan.velocity(in: window)
            return v.x < 0 && abs(v.x) > abs(v.y)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let window else { return }
            switch g.state {
            case .began:
                fired = false
            case .changed:
                let t = g.translation(in: window)
                if !fired, t.x < -28, abs(t.x) > abs(t.y) {   // low threshold → sensitive
                    fired = true
                    action()
                }
            default:
                break
            }
        }
    }
}
