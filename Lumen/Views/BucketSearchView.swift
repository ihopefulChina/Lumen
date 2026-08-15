import SwiftUI

struct BucketSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if model.searchController.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("已扫描 \(model.searchController.progress.scanned) 项")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("停止") { model.cancelBucketSearch() }
                    .buttonStyle(.link)
            } else {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            filterMenu
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.searchController.errorMessage {
            ContentUnavailableView {
                Label("无法完成搜索", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("再试一次") { Task { await model.runBucketSearch() } }
            }
        } else if model.searchController.results.isEmpty && !model.searchController.isSearching {
            ContentUnavailableView(
                "没有找到项目",
                systemImage: "magnifyingglass",
                description: Text("尝试更短的关键词或减少筛选条件。")
            )
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        Table(of: OSSObject.self, selection: $selection) {
            TableColumn("名称") { object in
                HStack(spacing: 6) {
                    if object.isImage {
                        ThumbnailView(object: object, style: .row)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        FinderFileIcon(key: object.key, size: 16)
                    }
                    Text(object.name)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { await model.openSearchResult(object) }
                }
            }
            TableColumn("位置") { object in
                Text(location(of: object))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("大小") { object in
                Text(ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("修改时间") { object in
                Text(object.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(150)
        } rows: {
            ForEach(model.searchController.results) { object in
                TableRow(object)
                    .contextMenu {
                        Button("快速查看") { Task { await model.quickLook(object) } }
                        Button("显示所在文件夹") { Task { await model.openSearchResult(object) } }
                    }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("类型") {
                ForEach(BucketSearchKind.allCases) { kind in
                    Button {
                        model.searchFilter.kind = kind
                    } label: {
                        if model.searchFilter.kind == kind {
                            Label(kind.title, systemImage: "checkmark")
                        } else {
                            Text(kind.title)
                        }
                    }
                }
            }
            Section("大小") {
                filterButton("任意大小", minimum: nil, maximum: nil)
                filterButton("大于 10 MB", minimum: 10 * 1_024 * 1_024, maximum: nil)
                filterButton("大于 100 MB", minimum: 100 * 1_024 * 1_024, maximum: nil)
                filterButton("小于 1 MB", minimum: nil, maximum: 1 * 1_024 * 1_024)
            }
            Section("修改时间") {
                dateButton("任意时间", range: .any)
                dateButton("最近 24 小时", range: .lastDays(1))
                dateButton("最近 7 天", range: .lastDays(7))
                dateButton("最近 30 天", range: .lastDays(30))
            }
            if model.searchFilter != .all {
                Divider()
                Button("清除筛选") { model.searchFilter = .all }
            }
        } label: {
            Label("筛选", systemImage: model.searchFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("筛选搜索结果")
    }

    private func filterButton(_ title: String, minimum: Int64?, maximum: Int64?) -> some View {
        Button {
            model.searchFilter.minimumSize = minimum
            model.searchFilter.maximumSize = maximum
        } label: {
            if model.searchFilter.minimumSize == minimum,
               model.searchFilter.maximumSize == maximum {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func dateButton(_ title: String, range: BucketSearchDateRange) -> some View {
        Button {
            model.searchFilter.modified = range
        } label: {
            if model.searchFilter.modified == range {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var statusText: String {
        let progress = model.searchController.progress
        if model.searchController.snapshot?.isIncomplete == true {
            return "找到 \(progress.matched) 项（结果可能不完整）"
        }
        return "找到 \(progress.matched) 项"
    }

    private func location(of object: OSSObject) -> String {
        let prefix = PathTemplate.parentPrefix(object.key)
        return prefix.isEmpty ? (model.selectedBucketName ?? "/") : prefix
    }
}
