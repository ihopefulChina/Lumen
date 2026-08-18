import SwiftUI

struct BucketSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []

    var body: some View {
        // Table cells are hosted by AppKit; capture the model reference up
        // front so cell closures never read @Environment.
        let modelRef = model
        return Group {
            if let error = modelRef.searchController.errorMessage {
                VStack(spacing: 8) {
                    Text("无法完成搜索")
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    Button("再试一次") { Task { await modelRef.runBucketSearch() } }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if modelRef.searchController.results.isEmpty && !modelRef.searchController.isSearching {
                Text("没有匹配的项目")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsTable(modelRef)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resultsTable(_ modelRef: AppModel) -> some View {
        Table(of: OSSObject.self, selection: $selection) {
            TableColumn("名称") { object in
                HStack(spacing: 6) {
                    if object.isImage {
                        ThumbnailView(object: object, style: .row, loadClient: { modelRef.makeClient() })
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
                    Task { await modelRef.openSearchResult(object) }
                }
            }
            TableColumn("位置") { object in
                Text(location(modelRef, of: object))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("大小") { object in
                Text(Formatters.bytes(object.size))
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
            ForEach(modelRef.searchController.results) { object in
                TableRow(object)
                    .contextMenu {
                        Button("快速查看") { Task { await modelRef.quickLook(object) } }
                        Button("显示所在文件夹") { Task { await modelRef.openSearchResult(object) } }
                    }
            }
        }
    }

    private func location(_ modelRef: AppModel, of object: OSSObject) -> String {
        let prefix = PathTemplate.parentPrefix(object.key)
        return prefix.isEmpty ? (modelRef.selectedBucketName ?? "/") : prefix
    }
}

struct BucketSearchFilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Menu content can be rendered in a separate hosting context; use the
        // resolved reference instead of the environment.
        let modelRef = model
        Menu {
            Section("类型") {
                ForEach(BucketSearchKind.allCases) { kind in
                    Button {
                        modelRef.searchFilter.kind = kind
                    } label: {
                        if modelRef.searchFilter.kind == kind {
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
}
