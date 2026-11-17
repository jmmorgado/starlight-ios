//
//  StarlightHandoff.swift
//  Starlight
//
//  Handoff between the user's iPhone and iPad (same app, same Apple ID). No keys or private data
//  go in an activity: only what identifies where you are (tab, PC, game).
//

import UIKit

@objc(StarlightHandoff)
final class StarlightHandoff: NSObject {
    @objc static let shared = StarlightHandoff()

    /// Browsing Starlight (tab, PC, game page)
    @objc static let browseType = "com.jmmorgado.starlight.browse"

    private var activity: NSUserActivity?

    /// What the other device sends; applied once Home is ready
    private var pending: [String: Any]?
    var onBrowse: (([String: Any]) -> Void)? {
        didSet { deliverPending() }
    }

    /// Where you are now, offered to your other devices
    func advertiseBrowse(_ info: [String: Any], title: String) {
        let activity = self.activity ?? NSUserActivity(activityType: Self.browseType)
        activity.title = title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = info
        activity.needsSave = true
        self.activity = activity
        // The scene keeps it current while the app is in front
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication }) {
            scene.userActivity = activity
        }
        activity.becomeCurrent()
    }

    /// From the scene (or a cold start): an activity continued from another device
    @objc func handle(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == Self.browseType else { return false }
        pending = activity.userInfo as? [String: Any] ?? [:]
        deliverPending()
        return true
    }

    private func deliverPending() {
        guard let info = pending, let onBrowse = onBrowse else { return }
        pending = nil
        DispatchQueue.main.async { onBrowse(info) }
    }
}
