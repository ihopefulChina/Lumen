import AppKit
import SwiftUI

struct TransferTray: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var expanded = true

    private var jobs: [TransferJob] { model.transfers.jobs }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                header
                if expanded {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(jobs) { job in
                                TransferRow(job: job)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: listHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var listHeight: CGFloat {
        min(CGFloat(max(jobs.count, 1)) * 52, 260)
    }

    private var header: some View {
        HStack {
            Button {
                Motion.run(reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                    if model.transfers.activeCount > 0 {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起传输列表" : "展开传输列表")
            .help(expanded ? "收起传输列表" : "展开传输列表")
            Spacer()
            Button("打开传输中心") {
                openWindow(id: "transfers")
            }
            .controlSize(.small)
            if jobs.contains(where: { $0.status == .running }) {
                Button("全部暂停") { model.transfers.pauseAll() }
                    .controlSize(.small)
            } else if jobs.contains(where: { $0.status == .paused }) {
                Button("全部继续") { model.transfers.resumeAll() }
                .controlSize(.small)
            }
            if model.transfers.activeCount > 0 {
                Button("全部取消") {
                    model.transfers.cancelAll()
                }
                .controlSize(.small)
            }
        }
    }

    private var title: String {
        let active = model.transfers.activeCount
        let total = jobs.count
        if active > 0 { return "正在传输 \(active) 项" }
        return total > 0 ? "传输 · \(total) 项" : "传输"
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let job: TransferJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if job.status == .running || job.status == .queued {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                } else if let error = job.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if job.status == .completed, let url = job.publicURL {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(job.status == .running ? "\(Int(job.progress * 100))%" : statusLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            if job.status == .running {
                Button {
                    model.transfers.pause(job.id)
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("暂停 \(job.title)")
                .help("暂停 \(job.title)")
            } else if job.status == .paused {
                Button {
                    model.transfers.resume(job.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("继续 \(job.title)")
                .help("继续 \(job.title)")
            } else if job.isActive {
                Button {
                    model.transfers.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消 \(job.title)")
                .help("取消 \(job.title)")
            } else if job.status == .failed, model.transfers.canRetry(job.id) {
                Button("重试") {
                    model.transfers.retry(job.id)
                }
                .controlSize(.small)
            } else if job.status == .failed,
                      let reason = model.transfers.unavailableRetryReason(job.id) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(reason)
                    .help(reason)
            } else if job.status == .completed,
                      job.kind == .upload,
                      let url = job.publicURL {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    Haptics.alignment()
                }
                .controlSize(.small)
                .help("复制上传链接")
            }
        }
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .running: job.kind == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    private var color: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .paused: .secondary
        default: .accentColor
        }
    }

    private var statusLabel: String {
        switch job.status {
        case .queued: "排队"
        case .running: "进行中"
        case .paused: "已暂停"
        case .completed: job.integrityVerified ? "已校验" : "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

struct TransferMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.transfers.jobs.isEmpty {
            Text("没有传输任务")
        } else {
            let jobs = model.transfers.jobs
            ForEach(jobs.prefix(12)) { job in
                Button("\(job.title) · \(status(job))") {
                    openWindow(id: "transfers")
                }
            }
            if jobs.count > 12 {
                Text("还有 \(jobs.count - 12) 项")
            }
        }
        Divider()
        Button("打开传输中心") { openWindow(id: "transfers") }
        Button("打开 Lumen") { openWindow(id: "main") }
        if model.transfers.activeCount > 0 {
            Button("取消全部") { model.transfers.cancelAll() }
        }
    }

    private func status(_ job: TransferJob) -> String {
        switch job.status {
        case .running: "\(Int(job.progress * 100))%"
        case .queued: "排队"
        case .paused: "已暂停"
        case .completed: job.integrityVerified ? "完成 · 已校验" : "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}
