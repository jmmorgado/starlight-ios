//
//  StarlightHandoff.swift
//  Starlight
//
//  Handoff between the user's iPhone and iPad (same app, same Apple ID). No keys or private data
//  go in an activity: only what identifies where you are (tab, PC, game).
//

import UIKit

@objc(StarlightHandoff)
final class StarlightHandoff: NSObject, NSUserActivityDelegate {
    @objc static let shared = StarlightHandoff()

    /// Browsing Starlight: tab, PC and the game page that's open
    @objc static let browseType = "com.jmmorgado.starlight.browse"
    /// Streaming a game: the PC and the game
    @objc static let streamType = "com.jmmorgado.starlight.stream"

    private var browseActivity: NSUserActivity?
    private var streamActivity: NSUserActivity?

    /// Browsing continued from another device; applied once Home is ready
    private var pendingBrowse: [String: Any]?
    var onBrowse: (([String: Any]) -> Void)? {
        didSet { deliverPending() }
    }

    /// A stream continued from another device (MainFrameViewController resumes it); applied once ready
    private var pendingStream: [String: Any]?
    @objc var onStream: (([String: Any]) -> Void)? {
        didSet { deliverPending() }
    }

    /// The stream on this device was continued on another one (StreamFrameViewController stops streaming)
    @objc var onStreamContinued: (() -> Void)?

    // MARK: Offering

    /// Where you are in Starlight (ignored while a stream is offered)
    func advertiseBrowse(_ info: [String: Any], title: String) {
        let activity = browseActivity ?? NSUserActivity(activityType: Self.browseType)
        configure(activity, title: title, info: info)
        browseActivity = activity
        if streamActivity == nil {
            makeCurrent(activity)
        }
    }

    /// The game streaming now, so it can be picked up on your other device
    @objc func advertiseStream(hostUUID: String, hostName: String, appID: String, appUUID: String?, appName: String) {
        let activity = streamActivity ?? NSUserActivity(activityType: Self.streamType)
        var info: [String: Any] = ["host": hostUUID, "hostName": hostName, "app": appID, "appName": appName]
        if let uuid = appUUID, !uuid.isEmpty { info["uuid"] = uuid }
        configure(activity, title: "Playing \(appName)", info: info)
        // Continuing it elsewhere tells this device to let go of the stream
        activity.supportsContinuationStreams = false
        activity.delegate = self
        streamActivity = activity
        makeCurrent(activity)
    }

    /// The stream ended here: offer browsing again
    @objc func endStream() {
        streamActivity?.invalidate()
        streamActivity = nil
        onStreamContinued = nil
        if let browse = browseActivity {
            makeCurrent(browse)
        }
    }

    private func configure(_ activity: NSUserActivity, title: String, info: [String: Any]) {
        activity.title = title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = info
        activity.needsSave = true
    }

    private func makeCurrent(_ activity: NSUserActivity) {
        // The scene keeps it current while the app is in front
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication }) {
            scene.userActivity = activity
        }
        activity.becomeCurrent()
    }

    func userActivityWasContinued(_ userActivity: NSUserActivity) {
        guard userActivity === streamActivity else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStreamContinued?()
        }
    }

    // MARK: Receiving

    /// From the scene (or a cold start): an activity continued from another device
    @objc func handle(_ activity: NSUserActivity) -> Bool {
        let info = activity.userInfo as? [String: Any] ?? [:]
        switch activity.activityType {
        case Self.browseType:
            pendingBrowse = info
        case Self.streamType:
            pendingStream = info
        default:
            return false
        }
        deliverPending()
        return true
    }

    /// The game page for a game (a stream whose game isn't the one running on the PC any more)
    @objc func openGamePage(hostUUID: String, appID: String, appUUID: String?) {
        var game: [String: Any] = ["app": appID]
        if let uuid = appUUID, !uuid.isEmpty { game["uuid"] = uuid }
        pendingBrowse = ["tab": StarlightTab.home.rawValue, "host": hostUUID, "game": game]
        deliverPending()
    }

    private func deliverPending() {
        if let info = pendingBrowse, let onBrowse = onBrowse {
            pendingBrowse = nil
            DispatchQueue.main.async { onBrowse(info) }
        }
        if let info = pendingStream, let onStream = onStream {
            pendingStream = nil
            DispatchQueue.main.async { onStream(info) }
        }
    }
}
