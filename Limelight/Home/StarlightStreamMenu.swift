//
//  StarlightStreamMenu.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Stream menu (shown over a running stream)

/// Liquid Glass menu over a running stream. It lives for the whole stream: closed, it is a small
/// ••• glass button in the top-left corner (shown for a few seconds, then hidden); pulling from the
/// left edge or dragging the button stretches it, and past a threshold it morphs into the menu panel
/// (and back into the button when closed). Holding Start on a controller opens it too.
/// The game is never dimmed. Works by touch and with the D-pad / left stick and the face buttons.
@objc(StarlightStreamMenu)
final class StarlightStreamMenu: NSObject {
    private let state: StreamMenuState
    private lazy var host = StreamMenuHostController(state: state)

    /// "resume", "keyboard", "pip", "display", "stats", "disconnect", "quit"
    @objc var onAction: ((String) -> Void)? {
        didSet { state.onAction = onAction }
    }

    /// Full-screen and transparent: touches outside the button (closed) reach the game
    @objc var viewController: UIViewController { host }

    @objc var isOpen: Bool { state.isOpen }

    @objc func open() { state.open() }

    @objc func close() { state.close() }

    /// Shows the ••• button for a few seconds (when the stream starts)
    @objc func flashButton() { state.flashButton(seconds: 4) }

    /// The left-edge swipe, from UIKit: horizontal translation while the finger moves
    @objc func dragChanged(_ translation: CGFloat) { state.dragChanged(translation) }

    /// End of the swipe: translation, and where it would have ended given its speed
    @objc func dragEnded(_ translation: CGFloat, predicted: CGFloat) { state.dragEnded(translation, predicted: predicted) }

    /// Holding Start on the controller pulls the button open like a finger would (0…1 of the hold)
    @objc func holdProgress(_ progress: CGFloat) { state.holdProgress(progress) }

    @objc func holdCancelled() { state.dragEnded(0, predicted: 0) }

    @objc init(gameName: String, statsVisible: Bool) {
        state = StreamMenuState(gameName: gameName, statsVisible: statsVisible)
        super.init()
    }

    @objc func setStatsVisible(_ visible: Bool) {
        state.statsVisible = visible
    }

    /// Shows "Picture in Picture" (Settings › Picture in Picture on, and supported)
    @objc func setPictureInPictureAvailable(_ available: Bool) {
        state.pipAvailable = available
    }

    /// With a TV connected: 1 = mirroring (offer the TV as a second screen), 2 = stream on the TV (offer mirroring), 0 = no TV
    @objc func setDisplayOption(_ option: Int) {
        state.displayOption = option
    }

    /// Controller input: "up", "down", "left", "right", "select", "back"
    @objc func navigate(_ action: String) {
        state.navigate(action)
    }

    /// Stream Settings as MainFrameViewController's dictionary (same keys as StreamSettingsView)
    @objc func setStreamSettings(_ settings: [String: Any]) {
        state.loadSettings(settings)
    }

    /// Changed settings (the full dictionary to save) and whether the stream must reconnect to use them
    @objc var onSettings: (([String: Any], Bool) -> Void)? {
        didSet { state.onSettings = onSettings }
    }

    /// Rubylight: the PC's guest list (GET /session/guests). A new request to join opens the menu on Guests.
    @objc func setGuests(_ info: [String: Any]) {
        state.loadGuests(info)
    }

    /// Guest actions: ("approve" | "deny" | "kick" | "revoke" | "permission", guest id, permission or "")
    @objc var onGuestAction: ((String, String, String) -> Void)? {
        didSet { state.onGuestAction = onGuestAction }
    }
}

final class StreamMenuState: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        var prominent = false
        var destructive = false
    }

    enum Page { case main, settings, controls, guests }

    /// Changing these needs the stream to reconnect
    struct VideoValues: Equatable {
        var width = 1920
        var height = 1080
        var framerate = 60
        var bitrate = 20000
        var codec = 0
        var hdr = false
        var framePacing = false
        var multiController = true
    }

    /// These apply right away
    struct ControlValues: Equatable {
        var onscreenControls = 1
        var absoluteTouch = false
        var swapABXY = false
    }

    struct Resolution: Equatable {
        let label: String
        let width: Int
        let height: Int
    }

    let gameName: String
    @Published var page: Page = .main
    @Published var video = VideoValues()
    @Published var controls = ControlValues()
    /// The video settings as saved: the edits are only saved by Apply & Reconnect
    var savedVideo = VideoValues()
    var resolutions: [Resolution] = []
    var maxFramerate = 60
    /// Settings this menu doesn't show (Host), passed back unchanged
    private var others: [String: Any] = [:]
    var onSettings: (([String: Any], Bool) -> Void)?
    @Published var statsVisible: Bool
    @Published var pipAvailable = false
    @Published var displayOption = 0
    @Published var confirmQuit = false
    @Published var focus = 0
    var onAction: ((String) -> Void)?

    // MARK: Guests (Rubylight)

    struct Guest: Identifiable, Equatable {
        let id: String
        let name: String
        var permission: String
        var waiting: Bool
        var streaming: Bool
    }

    /// The PC offers guests and this device may manage them (it plays the game)
    @Published private(set) var guestsAvailable = false
    @Published private(set) var guestRequests: [Guest] = []
    @Published private(set) var guests: [Guest] = []
    private var seenRequests = Set<String>()
    var onGuestAction: ((String, String, String) -> Void)?

    static let guestPermissions = ["view", "controller", "controller-keyboard-mouse"]
    static func permissionName(_ permission: String) -> String {
        switch permission {
        case "view": return "View Only"
        case "controller-keyboard-mouse": return "Controller, Keyboard & Mouse"
        default: return "Controller"
        }
    }

    func loadGuests(_ info: [String: Any]) {
        func id(_ value: Any?) -> String? {
            if let n = value as? NSNumber { return n.stringValue }
            if let s = value as? String, !s.isEmpty { return s }
            return nil
        }
        let manage = (info["manage"] as? NSNumber)?.boolValue ?? false
        let waiting: [Guest] = (info["waiting"] as? [[String: Any]] ?? []).compactMap {
            guard let gid = id($0["id"]) else { return nil }
            return Guest(id: gid, name: $0["name"] as? String ?? "A device", permission: "", waiting: true, streaming: false)
        }
        let joined: [Guest] = (info["guests"] as? [[String: Any]] ?? []).compactMap {
            guard let gid = id($0["id"]) else { return nil }
            return Guest(id: gid, name: $0["name"] as? String ?? "A device",
                         permission: $0["permission"] as? String ?? "controller",
                         waiting: false, streaming: ($0["streaming"] as? NSNumber)?.boolValue ?? false)
        }
        let available = manage
        if available != guestsAvailable { guestsAvailable = available }
        if waiting != guestRequests { withAnimation(Self.pageSpring) { guestRequests = waiting } }
        if joined != guests { withAnimation(Self.pageSpring) { guests = joined } }

        // Someone new asks to join: bring up Guests so the player can answer (by touch or controller)
        let newRequests = Set(waiting.map(\.id)).subtracting(seenRequests)
        seenRequests.formUnion(waiting.map(\.id))
        if manage && !newRequests.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            if isOpen {
                if page != .guests { go(to: .guests, forward: true, focus: 0) }
            } else {
                open()
                page = .guests
                focus = 0
            }
        }
    }

    /// Focus order on the Guests page: Let in / Deny for each request, then each guest's permission, Kick and Block
    var guestFocusIDs: [String] {
        guestRequests.flatMap { ["approve:\($0.id)", "deny:\($0.id)"] }
            + guests.flatMap { ["perm:\($0.id)", "kick:\($0.id)", "block:\($0.id)"] }
    }

    func guestAction(_ focusID: String, delta: Int = 1) {
        let parts = focusID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (kind, gid) = (parts[0], parts[1])
        switch kind {
        case "approve": onGuestAction?("approve", gid, "")
        case "deny": onGuestAction?("deny", gid, "")
        case "kick": onGuestAction?("kick", gid, "")
        case "block": onGuestAction?("revoke", gid, "")
        case "perm":
            guard let index = guests.firstIndex(where: { $0.id == gid }) else { return }
            let options = Self.guestPermissions
            let current = options.firstIndex(of: guests[index].permission) ?? 1
            let next = options[(current + delta + options.count) % options.count]
            guests[index].permission = next
            onGuestAction?("permission", gid, next)
        default: break
        }
    }

    func leaveGuests() {
        go(to: .main, forward: false, focus: mainFocusIDs.firstIndex(of: "guests") ?? 0)
    }

    private func navigateGuests(_ action: String) {
        let ids = guestFocusIDs
        let count = ids.count
        if action == "back" { leaveGuests(); return }
        guard count > 0 else { return }
        focus = min(focus, count - 1)
        let id = ids[focus]
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "left":
            if id.hasPrefix("perm:") { guestAction(id, delta: -1) } else if focus > 0 { focus -= 1 }
        case "right":
            if id.hasPrefix("perm:") { guestAction(id, delta: 1) } else if focus < count - 1 { focus += 1 }
        case "select": guestAction(id)
        default: break
        }
    }

    // MARK: Page navigation

    /// Entering a section pushes from the right; going back pops to the right
    @Published private(set) var pageForward = true
    static let pageSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// The direction is set first (so the outgoing page also slides the right way), then the page changes
    private func go(to newPage: Page, forward: Bool, focus newFocus: Int) {
        pageForward = forward
        DispatchQueue.main.async {
            withAnimation(Self.pageSpring) {
                self.page = newPage
                self.focus = newFocus
            }
        }
    }

    // MARK: Open / close and the ••• button

    @Published private(set) var isOpen = false
    @Published private(set) var buttonVisible = false
    /// How far the button is being pulled (points, from the left edge or the button itself)
    @Published private(set) var drag: CGFloat = 0
    private var hideWork: DispatchWorkItem?
    private var passedThreshold = false
    /// Pull this far (or flick) to open
    static let openDistance: CGFloat = 70
    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    func open() {
        hideWork?.cancel()
        // Each opening starts on the main page
        page = .main
        confirmQuit = false
        focus = 0
        passedThreshold = false
        withAnimation(Self.spring) {
            isOpen = true
            drag = 0
        }
    }

    func close() {
        guard isOpen else { return }
        // The panel shrinks back into the button, which then fades away
        withAnimation(Self.spring) {
            isOpen = false
            buttonVisible = true
        }
        scheduleHide(after: 2.5)
    }

    func flashButton(seconds: Double) {
        guard !isOpen else { return }
        withAnimation(.easeOut(duration: 0.3)) { buttonVisible = true }
        scheduleHide(after: seconds)
    }

    func dragChanged(_ translation: CGFloat) {
        guard !isOpen else { return }
        hideWork?.cancel()
        if !buttonVisible {
            withAnimation(.easeOut(duration: 0.15)) { buttonVisible = true }
        }
        drag = max(0, translation)
        let passed = drag >= Self.openDistance
        if passed && !passedThreshold {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        passedThreshold = passed
    }

    func holdProgress(_ progress: CGFloat) {
        guard !isOpen else { return }
        // Ease out, so it feels pulled; stops just short of the open distance (the hold opens it at 1 s)
        let p = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - p, 2)
        hideWork?.cancel()
        if !buttonVisible {
            withAnimation(.easeOut(duration: 0.15)) { buttonVisible = true }
        }
        drag = eased * (Self.openDistance - 1)
    }

    func dragEnded(_ translation: CGFloat, predicted: CGFloat) {
        guard !isOpen else { return }
        if translation >= Self.openDistance || predicted >= Self.openDistance * 2.5 {
            open()
        } else {
            passedThreshold = false
            withAnimation(Self.spring) { drag = 0 }
            scheduleHide(after: 2)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen, self.drag == 0 else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.buttonVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    init(gameName: String, statsVisible: Bool) {
        self.gameName = gameName
        self.statsVisible = statsVisible
    }

    var items: [Item] {
        if confirmQuit {
            return [
                Item(id: "quit", title: "Quit Game", symbol: "xmark.circle.fill", destructive: true),
                Item(id: "cancelQuit", title: "Cancel", symbol: "arrow.uturn.backward")
            ]
        }
        var list = [
            Item(id: "resume", title: "Back to Game", symbol: "play.fill", prominent: true),
            Item(id: "keyboard", title: "Keyboard", symbol: "keyboard")
        ]
        if !resolutions.isEmpty {
            list.append(Item(id: "settings", title: "Stream Settings", symbol: "slider.horizontal.3"))
        }
        if settingsLoaded {
            list.append(Item(id: "controls", title: "Controls", symbol: "gamecontroller"))
        }
        if guestsAvailable {
            let waiting = guestRequests.count
            let title = waiting > 0 ? "Guests · \(waiting) waiting" : (guests.isEmpty ? "Guests" : "Guests · \(guests.count)")
            list.append(Item(id: "guests", title: title, symbol: "person.2.fill", prominent: waiting > 0))
        }
        if pipAvailable {
            list.append(Item(id: "pip", title: "Picture in Picture", symbol: "pip.enter"))
        }
        if displayOption == 1 {
            list.append(Item(id: "display", title: "External Display", symbol: "tv"))
        } else if displayOption == 2 {
            list.append(Item(id: "display", title: "Mirror Display", symbol: "rectangle.on.rectangle"))
        }
        list += [
            Item(id: "stats", title: statsVisible ? "Hide Statistics" : "Show Statistics", symbol: "chart.bar.xaxis"),
            Item(id: "disconnect", title: "Stop Streaming", symbol: "stop.fill"),
            Item(id: "askQuit", title: "Quit Game", symbol: "xmark.circle.fill", destructive: true)
        ]
        return list
    }

    /// The Controls page shows once the stream's settings are known
    @Published private(set) var settingsLoaded = false

    /// Focus order on the main page
    var mainFocusIDs: [String] { items.map(\.id) }

    func activate(_ id: String) {
        switch id {
        case "settings":
            video = savedVideo
            go(to: .settings, forward: true, focus: 0)
        case "controls":
            go(to: .controls, forward: true, focus: 0)
        case "guests":
            go(to: .guests, forward: true, focus: 0)
        case "askQuit":
            withAnimation(Self.pageSpring) {
                confirmQuit = true
                focus = 1   // Cancel first, so a stray press doesn't quit
            }
        case "cancelQuit":
            withAnimation(Self.pageSpring) {
                confirmQuit = false
                focus = mainFocusIDs.firstIndex(of: "askQuit") ?? 0
            }
        default:
            onAction?(id)
        }
    }

    func navigate(_ action: String) {
        if page == .settings {
            navigateSettings(action)
            return
        }
        if page == .controls {
            navigateControls(action)
            return
        }
        if page == .guests {
            navigateGuests(action)
            return
        }
        let ids = mainFocusIDs
        let count = ids.count
        guard count > 0 else { return }
        focus = min(focus, count - 1)
        let id = ids[focus]
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "select": activate(id)
        case "back":
            if confirmQuit { activate("cancelQuit") } else { onAction?("resume") }
        default: break
        }
    }

    // MARK: Stream Settings page

    struct SettingRow: Identifiable {
        let id: String
        let title: String
        let value: String
        var isToggle = false
        var isOn = false
    }

    var videoChanged: Bool { video != savedVideo }

    private var framerates: [Int] { maxFramerate >= 120 ? [30, 60, 120] : [30, 60] }
    private static let bitrates = [5000, 10000, 15000, 20000, 30000, 40000, 50000, 60000, 80000, 100000, 120000, 150000]
    private var bitrateOptions: [Int] {
        Self.bitrates.contains(video.bitrate) ? Self.bitrates : (Self.bitrates + [video.bitrate]).sorted()
    }
    private var resolutionOptions: [Resolution] {
        if resolutions.contains(where: { $0.width == video.width && $0.height == video.height }) { return resolutions }
        return resolutions + [Resolution(label: "Custom", width: video.width, height: video.height)]
    }
    private static let codecNames = ["Automatic", "H.264", "HEVC", "AV1"]
    private static let oscNames = ["Off", "Auto", "Simple", "Full"]

    var videoRows: [SettingRow] {
        let res = resolutionOptions.first { $0.width == video.width && $0.height == video.height }
        return [
            SettingRow(id: "res", title: "Resolution", value: "\(res?.label ?? "Custom") · \(video.width)×\(video.height)"),
            SettingRow(id: "fps", title: "Frame Rate", value: "\(video.framerate) FPS"),
            SettingRow(id: "bitrate", title: "Bitrate", value: String(format: "%g Mbps", Double(video.bitrate) / 1000)),
            SettingRow(id: "codec", title: "Video Codec", value: Self.codecNames[min(max(video.codec, 0), 3)]),
            SettingRow(id: "hdr", title: "HDR", value: "", isToggle: true, isOn: video.hdr),
            SettingRow(id: "pacing", title: "Smoothest Video", value: "", isToggle: true, isOn: video.framePacing),
            SettingRow(id: "multi", title: "Multi-Controller Mode", value: "", isToggle: true, isOn: video.multiController)
        ]
    }

    var controlRows: [SettingRow] {
        [
            SettingRow(id: "touch", title: "Touch Mode", value: controls.absoluteTouch ? "Touchscreen" : "Touchpad"),
            SettingRow(id: "osc", title: "On-Screen Controls", value: Self.oscNames[min(max(controls.onscreenControls, 0), 3)]),
            SettingRow(id: "swap", title: "Swap A/B and X/Y", value: "", isToggle: true, isOn: controls.swapABXY)
        ]
    }

    /// Focus order on the page: the rows, then Apply & Reconnect (when there's something to apply)
    var settingsFocusIDs: [String] {
        videoRows.map(\.id) + (videoChanged ? ["apply"] : [])
    }

    func loadSettings(_ settings: [String: Any]) {
        func int(_ key: String, _ fallback: Int) -> Int { (settings[key] as? NSNumber)?.intValue ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { (settings[key] as? NSNumber)?.boolValue ?? fallback }
        resolutions = (settings["resolutions"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let label = dict["label"] as? String,
                  let w = (dict["width"] as? NSNumber)?.intValue,
                  let h = (dict["height"] as? NSNumber)?.intValue else { return nil }
            return Resolution(label: label, width: w, height: h)
        }
        maxFramerate = int("maxFramerate", 60)
        savedVideo = VideoValues(width: int("width", 1920), height: int("height", 1080),
                                 framerate: int("framerate", 60), bitrate: int("bitrate", 20000),
                                 codec: int("codec", 0), hdr: bool("hdr", false),
                                 framePacing: bool("framePacing", false),
                                 multiController: bool("multiController", true))
        video = savedVideo
        controls = ControlValues(onscreenControls: int("onscreenControls", 1),
                                 absoluteTouch: bool("absoluteTouch", false),
                                 swapABXY: bool("swapABXY", false))
        settingsLoaded = true
        others = ["optimizeGames": bool("optimizeGames", true), "audioOnPC": bool("audioOnPC", false),
                  "btMouse": bool("btMouse", false), "statsOverlay": bool("statsOverlay", false)]
    }

    private func dictionary(video values: VideoValues) -> [String: Any] {
        var dict = others
        dict["width"] = values.width
        dict["height"] = values.height
        dict["framerate"] = values.framerate
        dict["bitrate"] = values.bitrate
        dict["codec"] = values.codec
        dict["hdr"] = values.hdr
        dict["framePacing"] = values.framePacing
        dict["multiController"] = values.multiController
        dict["onscreenControls"] = controls.onscreenControls
        dict["absoluteTouch"] = controls.absoluteTouch
        dict["swapABXY"] = controls.swapABXY
        return dict
    }

    /// Controls: saved and applied now (with the video settings as saved)
    private func controlsChanged() {
        onSettings?(dictionary(video: savedVideo), false)
    }

    func applyAndReconnect() {
        guard videoChanged else { return }
        savedVideo = video
        onSettings?(dictionary(video: video), true)
    }

    func leaveSettings() {
        video = savedVideo
        go(to: .main, forward: false, focus: mainFocusIDs.firstIndex(of: "settings") ?? 0)
    }

    private func cycle<T: Equatable>(_ value: T, in options: [T], by delta: Int) -> T {
        guard !options.isEmpty else { return value }
        let index = options.firstIndex(of: value) ?? 0
        return options[(index + delta + options.count) % options.count]
    }

    /// ← / → (or a tap on the arrows): previous / next value; toggles: ← off, → on
    func adjust(_ id: String, by delta: Int) {
        switch id {
        case "res":
            let next = cycle(resolutionOptions.first { $0.width == video.width && $0.height == video.height }
                             ?? resolutionOptions[0], in: resolutionOptions, by: delta)
            video.width = next.width
            video.height = next.height
        case "fps": video.framerate = cycle(video.framerate, in: framerates, by: delta)
        case "bitrate": video.bitrate = cycle(video.bitrate, in: bitrateOptions, by: delta)
        case "codec": video.codec = cycle(video.codec, in: [0, 1, 2, 3], by: delta)
        case "hdr": video.hdr = delta > 0
        case "pacing": video.framePacing = delta > 0
        case "multi": video.multiController = delta > 0
        case "touch":
            controls.absoluteTouch.toggle()
            controlsChanged()
        case "osc":
            controls.onscreenControls = cycle(controls.onscreenControls, in: [0, 1, 2, 3], by: delta)
            controlsChanged()
        case "swap":
            controls.swapABXY = delta > 0
            controlsChanged()
        default: break
        }
    }

    /// ✕ (or a tap on the row): toggles flip, choices go to the next value, Apply applies
    func select(_ id: String) {
        switch id {
        case "apply": applyAndReconnect()
        case "hdr": adjust(id, by: video.hdr ? -1 : 1)
        case "pacing": adjust(id, by: video.framePacing ? -1 : 1)
        case "multi": adjust(id, by: video.multiController ? -1 : 1)
        case "swap": adjust(id, by: controls.swapABXY ? -1 : 1)
        default: adjust(id, by: 1)
        }
    }

    func leaveControls() {
        go(to: .main, forward: false, focus: mainFocusIDs.firstIndex(of: "controls") ?? 0)
    }

    private func navigateControls(_ action: String) {
        let ids = controlRows.map(\.id)
        let count = ids.count
        guard count > 0 else { return }
        focus = min(focus, count - 1)
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "left": adjust(ids[focus], by: -1)
        case "right": adjust(ids[focus], by: 1)
        case "select": select(ids[focus])
        case "back": leaveControls()
        default: break
        }
    }

    private func navigateSettings(_ action: String) {
        let ids = settingsFocusIDs
        let count = ids.count
        guard count > 0 else { return }
        focus = min(focus, count - 1)
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "left": adjust(ids[focus], by: -1)
        case "right": adjust(ids[focus], by: 1)
        case "select": select(ids[focus])
        case "back": leaveSettings()
        default: break
        }
    }
}

struct StreamMenuView: View {
    @ObservedObject var state: StreamMenuState
    @ObservedObject private var device = DeviceStatus.shared
    /// The ••• button and the panel share one glass shape, so one morphs into the other (iOS 26)
    @Namespace private var glassSpace
    /// The controller's focus ring slides between items
    @Namespace private var focusSpace

    var body: some View {
        StreamGlassContainer {
            ZStack(alignment: .topLeading) {
                if state.isOpen {
                    // Tap outside the panel to go back to the game (the game stays undimmed)
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { state.onAction?("resume") }
                        .accessibilityLabel("Back to game")
                        .accessibilityAddTraits(.isButton)

                    panel
                        .transition(Self.panelTransition)
                } else if state.buttonVisible {
                    moreButton
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.focus)
    }

    /// iOS 26 morphs the glass; earlier versions slide the panel in
    private static var panelTransition: AnyTransition {
        if #available(iOS 26.0, *) {
            return .opacity
        }
        return .move(edge: .leading).combined(with: .opacity)
    }

    // MARK: ••• button

    private var moreButton: some View {
        // Stretches as it's pulled, with resistance
        let stretch = min(state.drag * 0.6, 70)
        return Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: StreamMenuHostController.buttonSize + stretch, height: StreamMenuHostController.buttonSize)
            .modifier(StreamMenuGlass(namespace: glassSpace, capsule: true))
            .contentShape(Capsule())
            .onTapGesture { state.open() }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { state.dragChanged($0.translation.width) }
                    .onEnded { state.dragEnded($0.translation.width, predicted: $0.predictedEndTranslation.width) }
            )
            .padding(.leading, StreamMenuHostController.margin)
            .padding(.top, StreamMenuHostController.margin)
            .accessibilityLabel("Stream menu")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Stream Settings page

    private var settingsPanel: some View {
        let focusedID: String? = device.controllerConnected && state.settingsFocusIDs.indices.contains(state.focus)
            ? state.settingsFocusIDs[state.focus] : nil
        return VStack(alignment: .leading, spacing: 10) {
            Button { state.leaveSettings() } label: {
                Label("Stream Settings", systemImage: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the menu")

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Video")
                        ForEach(state.videoRows) { settingRow($0, focused: focusedID == $0.id) }
                        Text("Changes here reconnect the stream. The game keeps running on your PC.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 6)
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: focusedID) { id in
                    guard let id, id != "apply" else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }

            if state.videoChanged {
                Button { state.applyAndReconnect() } label: {
                    Label("Apply and Reconnect", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                .modifier(StreamMenuButtonStyle(prominent: true, destructive: false))
                .overlay(focusRing(Capsule(), lineWidth: 3, visible: focusedID == "apply"))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(StreamMenuState.pageSpring, value: state.videoChanged)
    }

    // MARK: Controls page

    private var controlsPanel: some View {
        let ids = state.controlRows.map(\.id)
        let focusedID: String? = device.controllerConnected && ids.indices.contains(state.focus) ? ids[state.focus] : nil
        return VStack(alignment: .leading, spacing: 10) {
            Button { state.leaveControls() } label: {
                Label("Controls", systemImage: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the menu")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.controlRows) { settingRow($0, focused: focusedID == $0.id) }
                    Text("These apply right away.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Guests page (Rubylight)

    private var guestsPanel: some View {
        let ids = state.guestFocusIDs
        let focusedID: String? = device.controllerConnected && ids.indices.contains(state.focus) ? ids[state.focus] : nil
        return VStack(alignment: .leading, spacing: 10) {
            Button { state.leaveGuests() } label: {
                Label("Guests", systemImage: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the menu")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if !state.guestRequests.isEmpty {
                        sectionTitle("Asking to join")
                        ForEach(state.guestRequests) { guest in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(guest.name, systemImage: "person.crop.circle.badge.questionmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    guestButton("Let In", id: "approve:\(guest.id)", prominent: true, destructive: false, focusedID: focusedID)
                                    guestButton("Deny", id: "deny:\(guest.id)", prominent: false, destructive: true, focusedID: focusedID)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    sectionTitle("Playing with you")
                    if state.guests.isEmpty {
                        Text("Nobody yet. Another device can join this game with Join.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(state.guests) { guest in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(guest.name, systemImage: guest.streaming ? "person.fill" : "person")
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if !guest.streaming {
                                    Text("Away").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            settingRow(StreamMenuState.SettingRow(id: "perm:\(guest.id)", title: "Can",
                                                                  value: StreamMenuState.permissionName(guest.permission)),
                                       focused: focusedID == "perm:\(guest.id)",
                                       adjust: { state.guestAction("perm:\(guest.id)", delta: $0) })
                            HStack(spacing: 8) {
                                guestButton("Kick", id: "kick:\(guest.id)", prominent: false, destructive: false, focusedID: focusedID)
                                guestButton("Block", id: "block:\(guest.id)", prominent: false, destructive: true, focusedID: focusedID)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text("Guests see your screen and play with their own controller. Block keeps a device out until the game ends.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func guestButton(_ title: String, id: String, prominent: Bool, destructive: Bool, focusedID: String?) -> some View {
        Button { state.guestAction(id) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .modifier(StreamMenuButtonStyle(prominent: prominent, destructive: destructive))
        .overlay(focusRing(Capsule(), lineWidth: 3, visible: focusedID == id))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    private func settingRow(_ row: StreamMenuState.SettingRow, focused: Bool, adjust: ((Int) -> Void)? = nil) -> some View {
        let change: (Int) -> Void = adjust ?? { state.adjust(row.id, by: $0) }
        return HStack(spacing: 8) {
            Text(row.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if row.isToggle {
                Toggle(row.title, isOn: Binding(get: { row.isOn },
                                                set: { state.adjust(row.id, by: $0 ? 1 : -1) }))
                    .labelsHidden()
                    .tint(starlightGold)
            } else {
                Button { change(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Previous \(row.title)")
                Text(row.value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button { change(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Next \(row.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(focused ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(focusRing(RoundedRectangle(cornerRadius: 14, style: .continuous), lineWidth: 2, visible: focused))
        .contentShape(Rectangle())
        .onTapGesture { if !row.isToggle { if adjust != nil { change(1) } else { state.select(row.id) } } }
        .id(row.id)
        .accessibilityElement(children: .combine)
    }

    /// One glass panel for every page: its width springs to the page's, and the page content
    /// slides inside it like a navigation push (forward) or pop (back)
    private var panel: some View {
        ZStack(alignment: .topLeading) {
            pageContent
                .id(state.page)
                .transition(pageTransition)
        }
        .frame(width: state.page == .main ? 300 : 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .modifier(StreamMenuGlass(namespace: glassSpace))
        .padding(.vertical, 12)
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var pageContent: some View {
        if state.page == .settings {
            settingsPanel
        } else if state.page == .controls {
            controlsPanel
        } else if state.page == .guests {
            guestsPanel
        } else {
            mainPanel
        }
    }

    private var pageTransition: AnyTransition {
        let forward = state.pageForward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var mainPanel: some View {
        let ids = state.mainFocusIDs
        let focusedID: String? = device.controllerConnected && ids.indices.contains(state.focus) ? ids[state.focus] : nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(state.confirmQuit ? "Quit \(state.gameName)?" : state.gameName)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(2)
            if state.confirmQuit {
                Text("The game closes on your PC. Unsaved progress may be lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Scrolls with a finger when the menu doesn't fit (iPhone in landscape)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.items) { item in
                            if item.id == "disconnect" {
                                Spacer(minLength: 8)
                            }
                            menuButton(item, focused: focusedID == item.id)
                                .id(item.id)
                            if item.id == "disconnect" {
                                Text("The game keeps running on your PC.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .onChange(of: focusedID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func menuButton(_ item: StreamMenuState.Item, focused: Bool) -> some View {
        Button(role: item.destructive ? .destructive : nil) {
            state.activate(item.id)
        } label: {
            Label(item.title, systemImage: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .modifier(StreamMenuButtonStyle(prominent: item.prominent, destructive: item.destructive))
        .overlay(focusRing(Capsule(), lineWidth: 3, visible: focused))
        .scaleEffect(focused ? 1.03 : 1)
        .accessibilityAddTraits(focused ? .isSelected : [])
        // Quit / Cancel slide in when confirming
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The gold controller focus ring: one shape that slides from item to item
    @ViewBuilder
    private func focusRing<S: Shape>(_ shape: S, lineWidth: CGFloat, visible: Bool) -> some View {
        if visible {
            shape
                .stroke(starlightGold, lineWidth: lineWidth)
                .matchedGeometryEffect(id: "focusRing", in: focusSpace)
        }
    }
}

/// Clear (most transparent) Liquid Glass. Button and panels share one glass id so they morph.
private struct StreamMenuGlass: ViewModifier {
    var namespace: Namespace.ID? = nil
    var capsule = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if capsule {
                content
                    .glassEffect(.clear.interactive(), in: Capsule())
                    .streamGlassID(namespace)
            } else {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .streamGlassID(namespace)
            }
        } else if capsule {
            content.background(.ultraThinMaterial, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

@available(iOS 26.0, *)
private extension View {
    @ViewBuilder
    func streamGlassID(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            glassEffectID("streamMenu", in: namespace)
        } else {
            self
        }
    }
}

/// GlassEffectContainer on iOS 26 (needed for the morph), nothing before
private struct StreamGlassContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 20) { content }
        } else {
            content
        }
    }
}

/// Hosts the menu over the stream for the whole session. Only the ••• button (closed) or the
/// whole screen (open) takes touches; everything else falls through to the game.
final class StreamMenuHostController: UIViewController {
    static let buttonSize: CGFloat = 44
    static let margin: CGFloat = 12

    private let state: StreamMenuState
    private let hosting: UIHostingController<StreamMenuView>

    init(state: StreamMenuState) {
        self.state = state
        hosting = UIHostingController(rootView: StreamMenuView(state: state))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let passthrough = StreamMenuPassthroughView()
        passthrough.state = state
        passthrough.backgroundColor = .clear
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}

private final class StreamMenuPassthroughView: UIView {
    weak var state: StreamMenuState?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let state, !isHidden, isUserInteractionEnabled else { return nil }
        if state.isOpen {
            return super.hitTest(point, with: event)
        }
        guard state.buttonVisible else { return nil }
        // The button's corner, with room for it to stretch and a forgiving margin
        let size = StreamMenuHostController.buttonSize
        let margin = StreamMenuHostController.margin
        let area = CGRect(x: safeAreaInsets.left, y: safeAreaInsets.top,
                          width: margin + size + 70 + 24, height: margin + size + 24)
        return area.contains(point) ? super.hitTest(point, with: event) : nil
    }
}

private struct StreamMenuButtonStyle: ViewModifier {
    let prominent: Bool
    let destructive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(starlightGold)
            } else {
                content.buttonStyle(.glass).tint(destructive ? .red : nil)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(starlightGold)
            } else {
                content.buttonStyle(.bordered).tint(destructive ? .red : nil)
            }
        }
    }
}
