import Foundation
import UserNotifications
import PipePlotCore

final class GuideNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled; super.init() }

    func requestAuthorization(completion: @escaping (String?) -> Void) {
        guard enabled else { completion(nil); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
            if let error { completion(error.localizedDescription) }
            else { completion(allowed ? nil : "Notifications are disabled for PipePlot. Enable them in macOS System Settings → Notifications to receive guide crossing alerts.") }
        }
    }
    func deliver(_ crossing: GuideCrossing) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "\(crossing.streamName) crossed \(crossing.guideLabel)"
        content.body = "\(crossing.direction == .rising ? "Rising" : "Falling"): \(NumericText.format(crossing.value)) (guide \(NumericText.format(crossing.threshold)))"
        content.sound = .default
        content.threadIdentifier = crossing.sessionID.uuidString
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
