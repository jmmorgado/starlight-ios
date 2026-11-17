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

/// Liquid Glass panel opened by swiping from the left edge or holding Start+Select on the controller.
/// Works by touch and, when a controller is connected, with the D-pad / left stick and the face buttons.
@objc(StarlightStreamMenu)
final class StarlightStreamMenu: NSObject {
    private let state: StreamMenuState
    private lazy var hosting: UIHostingController<StreamMenuView> = {
        let controller = UIHostingController(rootView: StreamMenuView(state: state))
        controller.view.backgroundColor = .clear
        controller.overrideUserInterfaceStyle = .dark
        return controller
    }()

    /// "resume", "keyboard", "pip", "display", "stats", "disconnect", "quit"
    @objc var onAction: ((String) -> Void)? {
        didSet { state.onAction = onAction }
    }

    @objc var viewController: UIViewController { hosting }

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
}

final class StreamMenuState: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        var prominent = false
        var destructive = false
    }

    enum Page { case main, settings }

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

    /// Controls live on the main page, once the stream's settings are known
    var showsControls: Bool { !confirmQuit && settingsLoaded }
    private var settingsLoaded = false

    /// Focus order on the main page: the buttons, with the Controls rows before Stop Streaming
    var mainFocusIDs: [String] {
        let ids = items.map(\.id)
        guard showsControls, let stop = ids.firstIndex(of: "disconnect") else { return ids }
        return Array(ids[..<stop]) + controlRows.map(\.id) + Array(ids[stop...])
    }

    private var controlIDs: Set<String> { Set(controlRows.map(\.id)) }

    func activate(_ id: String) {
        switch id {
        case "settings":
            video = savedVideo
            page = .settings
            focus = 0
        case "askQuit":
            confirmQuit = true
            focus = 1   // Cancel first, so a stray press doesn't quit
        case "cancelQuit":
            confirmQuit = false
            focus = mainFocusIDs.firstIndex(of: "askQuit") ?? 0
        default:
            onAction?(id)
        }
    }

    func navigate(_ action: String) {
        if page == .settings {
            navigateSettings(action)
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
        case "left": if controlIDs.contains(id) { adjust(id, by: -1) }
        case "right": if controlIDs.contains(id) { adjust(id, by: 1) }
        case "select":
            if controlIDs.contains(id) { select(id) } else { activate(id) }
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
        page = .main
        focus = mainFocusIDs.firstIndex(of: "settings") ?? 0
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
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Tap outside the panel to go back to the game
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { state.onAction?("resume") }
                .accessibilityLabel("Back to game")
                .accessibilityAddTraits(.isButton)

            panel
                .offset(x: shown ? 0 : -360)

        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shown = true }
        }
        .animation(.easeInOut(duration: 0.15), value: state.focus)
        .animation(.easeInOut(duration: 0.2), value: state.confirmQuit)
        .animation(.easeInOut(duration: 0.2), value: state.page)
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
                .overlay(Capsule().stroke(starlightGold, lineWidth: focusedID == "apply" ? 3 : 0))
                .transition(.opacity)
            }
        }
        .padding(20)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(StreamMenuGlass())
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .animation(.easeInOut(duration: 0.15), value: state.videoChanged)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    private func settingRow(_ row: StreamMenuState.SettingRow, focused: Bool) -> some View {
        HStack(spacing: 8) {
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
                Button { state.adjust(row.id, by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Previous \(row.title)")
                Text(row.value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button { state.adjust(row.id, by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Next \(row.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(focused ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(starlightGold, lineWidth: focused ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if !row.isToggle { state.select(row.id) } }
        .id(row.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var panel: some View {
        if state.page == .settings {
            settingsPanel
        } else {
            mainPanel
        }
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
            }

            // Scrolls with a finger when the menu doesn't fit (iPhone in landscape)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.items) { item in
                            if item.id == "disconnect" {
                                if state.showsControls {
                                    sectionTitle("Controls")
                                        .padding(.top, 6)
                                    ForEach(state.controlRows) { settingRow($0, focused: focusedID == $0.id) }
                                }
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
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(StreamMenuGlass())
        .padding(.vertical, 12)
        .padding(.leading, 12)
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
        .overlay(
            Capsule()
                .stroke(starlightGold, lineWidth: focused ? 3 : 0)
        )
        .scaleEffect(focused ? 1.03 : 1)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

private struct StreamMenuGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
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
