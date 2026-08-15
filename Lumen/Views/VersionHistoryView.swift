import SwiftUI

struct VersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var history: VersionHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if history.isLoading && history.rows.isEmpty {
                ProgressView("正在读取版本…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.rows.isEmpty {
                ContentUnavailableView(
                    history.markerOnly ? "没有可恢复的对象" : "没有版本记录",
                    systemImage: history.markerOnly ? "trash" : "clock.arrow.circlepath",
                    description: Text("版本记录仅在 Bucket 已启用版本控制时可用。")
                )
            } else {
                Table(of: VersionHistoryRow.self, selection: $history.selection) {
                    TableColumn("名称") { row in
                        Text(PathTemplate.lastComponent(row.key)).lineLimit(1)
                    }
                    TableColumn("日期") { row in
                        Text(row.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }.width(160)
                    TableColumn("大小") { row in
                        Text(row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .foregroundStyle(.secondary)
                    }.width(90)
                    TableColumn("状态") { row in
                        Text(status(row)).foregroundStyle(row.kind == .deleteMarker ? .orange : .secondary)
                    }.width(100)
                } rows: {
                    ForEach(history.rows) { row in
                        TableRow(row).contextMenu {
                            Button(row.kind == .deleteMarker ? "恢复已删除对象" : "恢复这个版本") {
                                Task { await history.restore(row) }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let error = history.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if history.isIncomplete {
                    Text("版本较多，当前结果可能不完整").foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(history.selectedRow?.kind == .deleteMarker ? "恢复对象" : "恢复版本") {
                    if let row = history.selectedRow { Task { await history.restore(row) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(history.selectedRow == nil || history.isRestoring)
            }
            .padding(14)
        }
        .frame(minWidth: 700, minHeight: 430)
        .navigationTitle(history.title)
        .task { await history.load() }
    }

    private func status(_ row: VersionHistoryRow) -> String {
        if row.kind == .deleteMarker { return "已删除" }
        return row.isCurrent ? "当前" : "历史版本"
    }
}
