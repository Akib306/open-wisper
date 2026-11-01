import AppKit
import Foundation
import WisperCore
import WisperPlatform

/// Content-free readiness, queried inside the GUI process whose TCC identity
/// actually delivers text. A terminal-launched child can have a different identity.
struct DeliveryReadinessReport: Codable, Sendable {
    let source: String
    let automaticInsertion: Bool
    let accessibilityGranted: Bool
    let eligibleFocusedField: Bool
    let reason: String?
    let metadata: [String: String]
}

@MainActor enum DeliveryDiagnostics {
    static let request = Notification.Name("dev.akib.openwisper.swift.delivery-readiness.request")
    static let response = Notification.Name("dev.akib.openwisper.swift.delivery-readiness.response")

    static func report(automaticInsertion: Bool, source: String) -> DeliveryReadinessReport {
        let status = AccessibilityDelivery().readiness()
        return DeliveryReadinessReport(source: source, automaticInsertion: automaticInsertion,
            accessibilityGranted: status.granted, eligibleFocusedField: status.eligible, reason: status.reason, metadata: status.metadata)
    }

    @MainActor private final class Reply { var report: DeliveryReadinessReport? }

    static func queryRunningApp() async -> DeliveryReadinessReport? {
        // Do not initialize AppKit/NSWorkspace in the requesting CLI: doing so
        // can register it as another GUI app and disturb the focus being probed.
        let id = UUID().uuidString
        let reply = Reply()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: response, object: id, queue: .main) { note in
            guard let json = note.userInfo?["report"] as? String, json.utf8.count < 4096,
                  let data = json.data(using: .utf8),
                  let report = try? JSONDecoder().decode(DeliveryReadinessReport.self, from: data) else { return }
            Task { @MainActor in reply.report = report }
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(request, object: id, userInfo: nil, deliverImmediately: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reply.report == nil && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return nil }
        }
        return reply.report
    }
}
