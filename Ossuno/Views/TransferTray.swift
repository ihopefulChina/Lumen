import AppKit
import SwiftUI

struct TransferTray: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            if model.transfers.activeCount > 0 {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.transfers.jobs.contains(where: { $0.status == .running }) {
                Button("全部暂停") { model.transfers.pauseAll() }
                    .buttonStyle(.borderless)
            } else if model.transfers.jobs.contains(where: { $0.status == .paused }) {
                Button("全部继续") { model.transfers.resumeAll() }
                    .buttonStyle(.borderless)
            }
            Button("打开传输中心") {
                openWindow(id: "transfers")
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var title: String {
        let active = model.transfers.activeCount
        let total = model.transfers.jobs.count
        if active > 0 { return "正在传输 \(active) 项" }
        return total > 0 ? "传输 · \(total) 项" : "传输"
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
        Button("打开 Ossuno") { openWindow(id: "main") }
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
