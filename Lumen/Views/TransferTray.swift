import AppKit
import SwiftUI

struct TransferTray: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                header
                if expanded {
                    LazyVStack(spacing: 8) {
                        ForEach(model.transfers.jobs.prefix(6)) { job in
                            TransferRow(job: job)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
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
            Spacer()
            if model.transfers.jobs.contains(where: { !$0.isActive }) {
                Button("清除已完成") {
                    model.transfers.clearFinished()
                }
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
        if active > 0 { return "正在传输 \(active) 项" }
        return "传输"
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
                .frame(width: 52, alignment: .trailing)
            if job.isActive {
                Button {
                    model.transfers.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消")
            } else if job.status == .completed, job.kind == .upload {
                Button("复制") {
                    if let url = job.publicURL {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        Haptics.alignment()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .running: job.kind == .upload ? "arrow.up.circle" : "arrow.down.circle"
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
        default: .accentColor
        }
    }

    private var statusLabel: String {
        switch job.status {
        case .queued: "排队"
        case .running: "进行中"
        case .completed: "完成"
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
            ForEach(model.transfers.jobs.prefix(8)) { job in
                Button("\(job.title) · \(status(job))") {
                    openWindow(id: "main")
                }
            }
        }
        Divider()
        Button("打开 Lumen") { openWindow(id: "main") }
        if model.transfers.activeCount > 0 {
            Button("取消全部") { model.transfers.cancelAll() }
        }
    }

    private func status(_ job: TransferJob) -> String {
        switch job.status {
        case .running: "\(Int(job.progress * 100))%"
        case .queued: "排队"
        case .completed: "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}
