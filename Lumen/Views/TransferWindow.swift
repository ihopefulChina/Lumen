import AppKit
import SwiftUI

enum TransferFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }

    func filter(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.filter { job in
            switch self {
            case .all: true
            case .active: job.isActive || job.status == .paused
            case .completed: job.status == .completed
            case .failed: job.status == .failed
            }
        }
    }
}

extension TransferJob {
    var canRevealInFinder: Bool {
        status == .completed
            && kind == .download
            && localURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
}

struct TransferWindow: View {
    @Environment(AppModel.self) private var model
    @State private var filter: TransferFilter = .all
    @State private var selection: Set<UUID> = []

    private var jobs: [TransferJob] { filter.filter(model.transfers.jobs) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if jobs.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("上传和下载任务会显示在这里。")
                )
            } else {
                table
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .navigationTitle("传输")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $filter) {
                ForEach(TransferFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 310)

            Spacer()

            if model.transfers.jobs.contains(where: { $0.status == .running }) {
                Button("全部暂停") { model.transfers.pauseAll() }
            }
            if model.transfers.jobs.contains(where: { $0.status == .paused }) {
                Button("全部继续") { model.transfers.resumeAll() }
            }
            Menu {
                Button("清除已结束的记录") { model.transfers.clearFinished() }
                    .disabled(!model.transfers.jobs.contains(where: \.isFinished))
                Divider()
                Button("取消未完成的传输", role: .destructive) { model.transfers.cancelAll() }
                    .disabled(!model.transfers.jobs.contains { $0.isActive || $0.status == .paused })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多传输操作")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.bar)
    }

    private var table: some View {
        Table(of: TransferJob.self, selection: $selection) {
            TableColumn("名称") { job in
                HStack(spacing: 8) {
                    Image(systemName: job.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(job.status == .failed ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).lineLimit(1)
                        Text(job.objectKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            TableColumn("进度") { job in
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    Text(progressText(job))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 170, ideal: 220)
            TableColumn("状态") { job in
                Text(statusText(job))
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(1)
            }
            .width(110)
            TableColumn("") { job in
                rowActions(job)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        } rows: {
            ForEach(jobs) { job in
                TableRow(job)
                    .contextMenu { contextMenu(job) }
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ job: TransferJob) -> some View {
        if job.status == .running {
            Button("暂停") { model.transfers.pause(job.id) }
                .controlSize(.small)
        } else if job.status == .paused {
            Button("继续") { model.transfers.resume(job.id) }
                .controlSize(.small)
        } else if job.status == .failed, model.transfers.canRetry(job.id) {
            Button("重试") { model.transfers.retry(job.id) }
                .controlSize(.small)
        } else if job.canRevealInFinder {
            Button("显示") { reveal(job) }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func contextMenu(_ job: TransferJob) -> some View {
        if job.status == .running {
            Button("暂停") { model.transfers.pause(job.id) }
        }
        if job.status == .paused {
            Button("继续") { model.transfers.resume(job.id) }
        }
        if job.status == .queued {
            Button("移到队列顶部") { model.transfers.moveToTop(job.id) }
        }
        if job.status == .failed, model.transfers.canRetry(job.id) {
            Button("重试") { model.transfers.retry(job.id) }
        }
        if job.canRevealInFinder {
            Button("在访达中显示") { reveal(job) }
        }
        if job.isActive || job.status == .paused {
            Divider()
            Button("取消传输", role: .destructive) { model.transfers.cancel(job.id) }
        }
    }

    private func progressText(_ job: TransferJob) -> String {
        let transferred = ByteCountFormatter.string(fromByteCount: job.transferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: job.total, countStyle: .file)
        guard job.status == .running,
              let rate = model.transfers.currentBytesPerSecond(job.id)
        else { return "\(transferred) / \(total)" }
        let rateText = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
        if let remaining = model.transfers.estimatedRemaining(job.id) {
            return "\(transferred) / \(total) · \(rateText)/s · \(Self.duration(remaining))"
        }
        return "\(transferred) / \(total) · \(rateText)/s"
    }

    private func statusText(_ job: TransferJob) -> String {
        switch job.status {
        case .queued: "排队"
        case .running: "传输中"
        case .paused: "已暂停"
        case .completed: job.integrityVerified ? "完成 · 已校验" : "已完成"
        case .failed: job.errorMessage ?? "失败"
        case .cancelled: "已取消"
        }
    }

    private var emptyTitle: String {
        filter == .all ? "没有传输" : "没有\(filter.title)的传输"
    }

    private func reveal(_ job: TransferJob) {
        guard let url = job.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "约 \(value) 秒" }
        if value < 3_600 { return "约 \(value / 60) 分钟" }
        return "约 \(value / 3_600) 小时"
    }
}
