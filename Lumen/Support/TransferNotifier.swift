import Foundation
import UserNotifications

enum TransferFinishNotice {
    static func content(jobs: [TransferJob], now: Date = .now) -> (title: String, body: String)? {
        let recent = jobs.filter { job in
            guard job.isFinished, let finishedAt = job.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) < 90
        }
        let completed = recent.filter { $0.status == .completed }
        let failed = recent.filter { $0.status == .failed }
        if completed.isEmpty, failed.isEmpty {
            return nil
        }
        if failed.isEmpty {
            if completed.count == 1 {
                let job = completed[0]
                let name = job.title
                return (
                    "传输完成",
                    job.kind == .upload ? "“\(name)”已上传" : "“\(name)”已下载"
                )
            }
            return ("传输完成", "已完成 \(completed.count) 项")
        }
        if completed.isEmpty {
            return ("传输失败", failed.count == 1 ? (failed[0].errorMessage ?? "1 项失败") : "\(failed.count) 项失败")
        }
        return ("传输已结束", "成功 \(completed.count) 项，失败 \(failed.count) 项")
    }
}

@MainActor
final class TransferNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TransferNotifier()

    func prepare() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func postQueueFinished(jobs: [TransferJob], sound: Bool) {
        guard let notice = TransferFinishNotice.content(jobs: jobs) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if sound {
            content.sound = .default
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
