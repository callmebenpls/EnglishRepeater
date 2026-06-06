import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @Binding var selectedTab: Int
    @State private var showFilePicker = false
    @State private var searchText = ""

    private var filteredItems: [LibraryItem] {
        if searchText.isEmpty { return vm.library }
        return vm.library.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Observe the stats object directly so minute-bumps re-render the card
                // (changes inside a nested @Published don't propagate via the outer VM).
                StatsCardContainer(stats: vm.stats)
                if vm.library.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
            .navigationTitle("音频库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio, .plainText, UTType(filenameExtension: "lrc") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        vm.addToLibrary(url: url)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索音频...")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("还没有音频")
                .font(.headline)
            Text("点击右上角 + 导入音频，或从其他 App 用\"打开方式\"分享")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: - List

    private var listView: some View {
        List {
            ForEach(filteredItems) { item in
                Button(action: {
                    vm.selectItem(item)
                    selectedTab = 1
                }) {
                    itemRow(item)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        vm.removeItem(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Row

    private func itemRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 12) {
            initialsBlock(for: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(formatDuration(item.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.systemGray5))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor(for: item))
                            .frame(width: geo.size.width * item.progressFraction, height: 3)
                    }
                }
                .frame(height: 3)
            }

            Spacer()

            if vm.currentItem?.id == item.id {
                Image(systemName: vm.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func initialsBlock(for item: LibraryItem) -> some View {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        let idx = abs(item.id.hashValue) % colors.count
        return Text(item.initials)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(colors[idx])
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func progressColor(for item: LibraryItem) -> Color {
        return item.progressFraction >= 1.0 ? .green : .blue
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        guard d > 0 else { return "--:--" }
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    LibraryView(selectedTab: .constant(0))
        .environmentObject(PlayerViewModel())
}

// MARK: - Stats Card

/// Thin observer wrapper. `@ObservedObject` here ensures the card re-renders when the
/// nested `ListeningStats` publishes, which the parent view-model's `@Published` chain
/// would otherwise drop.
private struct StatsCardContainer: View {
    @ObservedObject var stats: ListeningStats
    var body: some View {
        StatsCard(todayMinutes: stats.todayMinutes, totalMinutes: stats.totalMinutes)
    }
}

/// "TODAY · TOTAL" listening-time card. Bordered material card; ultra-light numbers,
/// caption labels above, "min" under. When today = 0, that column dims (the eye glides
/// past to the lifetime total).
private struct StatsCard: View {
    let todayMinutes: Int
    let totalMinutes: Int

    var body: some View {
        HStack(spacing: 0) {
            column(label: "TODAY", value: todayMinutes, dim: todayMinutes == 0)
            Text("·")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)   // visually align with the numbers, not the labels
            column(label: "TOTAL", value: totalMinutes, dim: false)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func column(label: String, value: Int, dim: Bool) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 52, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .opacity(dim ? 0.3 : 1.0)
            Text("min")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(dim ? 0.5 : 1.0)
        }
        .frame(maxWidth: .infinity)
    }
}
