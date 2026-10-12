import Foundation
import UserNotifications

/// A quota event worth notifying about.
struct QuotaNotification: Sendable, Equatable {
    enum Kind: String, Sendable {
        case warning
        case critical
        case restored
    }

    let provider: Provider
    let windowLabel: String
    let kind: Kind
    let utilization: Double
    let threshold: Double

    var title: String {
        switch kind {
        case .warning: "\(provider.displayName) quota warning"
        case .critical: "\(provider.displayName) quota critical"
        case .restored: "\(provider.displayName) quota recovered"
        }
    }

    var body: String {
        let percent = "\(Int(utilization.rounded()))%"
        return switch kind {
        case .warning:
            "\(windowLabel): \(percent) used (warns at \(Int(threshold))%)."
        case .critical:
            "\(windowLabel): \(percent) used (critical at \(Int(threshold))%). Consider waiting for the reset."
        case .restored:
            "\(windowLabel) is back to \(percent)."
        }
    }

    /// Stable per episode so a repeat replaces instead of stacking.
    var requestIdentifier: String {
        "aiusage.quota.\(provider.rawValue).\(windowLabel).\(kind.rawValue)"
    }
}

protocol QuotaNotificationDelivering: Sendable {
    func requestAuthorization() async -> Bool
    func deliver(_ notification: QuotaNotification) async
}

/// Delivers through UNUserNotificationCenter. Delivery when permission was
/// denied is a silent no-op; nothing throws.
struct UserNotificationQuotaDeliverer: QuotaNotificationDelivering {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func deliver(_ notification: QuotaNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.kind == .critical {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: notification.requestIdentifier,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Pure per-window episode policy: each window fires at most one warning and
/// one critical until it recovers, then fires at most one restored and
/// re-arms. Recovery requires dropping below the warning threshold minus
/// hysteresis so values jittering around the line don't spam.
enum QuotaNotificationPolicy {
    static let rearmHysteresis = 5.0

    struct Episode: Codable, Equatable, Sendable {
        var warned = false
        var critical = false
    }

    /// Evaluates one window. Returns the event to fire (if any) and the
    /// updated episode state to persist.
    static func evaluate(
        utilization: Double,
        warningThreshold: Double,
        criticalThreshold: Double,
        episode: Episode
    ) -> (event: QuotaNotification.Kind?, episode: Episode) {
        var episode = episode
        if utilization >= criticalThreshold {
            // Escalating past warning counts as having warned, so a later dip
            // into the warning band doesn't fire a stale warning.
            episode.warned = true
            guard !episode.critical else { return (nil, episode) }
            episode.critical = true
            return (.critical, episode)
        }
        if utilization >= warningThreshold {
            guard !episode.warned else { return (nil, episode) }
            episode.warned = true
            return (.warning, episode)
        }
        guard episode.warned || episode.critical else { return (nil, episode) }
        guard utilization < warningThreshold - rearmHysteresis else { return (nil, episode) }
        return (.restored, Episode())
    }
}
