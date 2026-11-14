//
//  StarlightSettings.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Settings tab

struct SettingsTab: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var steam = SteamManager.shared
    /// The screen pushed from the root (also set by ✕ on the controller)
    @State private var route: String?
    /// Read by MainFrameViewController when a pinned game, link or Shortcut launches a game
    @AppStorage("StarlightAutoWake") private var autoWake = true
    /// Read by MainFrameViewController on opening the app and a game page
    @AppStorage("StarlightConnectEarly") private var connectEarly = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        // Set by the test-build workflow; empty in release builds
        if let label = info?["StarlightBuildLabel"] as? String, !label.isEmpty {
            return "\(short) · \(label)"
        }
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    Section("Streaming") {
                        NavigationLink(tag: "stream", selection: $route) {
                            StreamSettingsView(model: model)
                        } label: {
                            Label("Stream Settings", systemImage: "slider.horizontal.3")
                        }
                        .settingsFocus("set-stream", scope: "settings") { route = "stream" }
                    }

                    Section("PCs") {
                        ForEach(model.hosts) { host in
                            NavigationLink(tag: "pc-\(host.id)", selection: $route) {
                                HostDetailView(model: model, hostId: host.id)
                            } label: {
                                HStack {
                                    Label(host.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    Text(host.paired ? (host.online ? "Online" : "Offline") : "Not paired")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .settingsFocus("set-pc-\(host.id)", scope: "settings") { route = "pc-\(host.id)" }
                        }
                        Button { model.command("addHost") } label: {
                            Label("Add PC by Address…", systemImage: "plus")
                        }
                        .settingsFocus("set-addpc", scope: "settings") { model.command("addHost") }
                    }

                    Section {
                        Toggle(isOn: $autoWake) {
                            Label("Wake PC Automatically", systemImage: "power")
                        }
                        .settingsFocus("set-autowake", scope: "settings", adjust: { autoWake = $0 > 0 }) { autoWake.toggle() }
                        Toggle(isOn: $connectEarly) {
                            Label("Connect Early", systemImage: "bolt.horizontal")
                        }
                        .settingsFocus("set-connectearly", scope: "settings", adjust: { connectEarly = $0 > 0 }) { connectEarly.toggle() }
                    } header: {
                        Text("Launching")
                    } footer: {
                        Text("Wake PC Automatically: when a pinned game, a starlight:// link or a Shortcut starts a game and the PC is asleep, Starlight wakes it and waits before streaming.\nConnect Early: when you open Starlight or a game page, Starlight checks the PC and wakes it if it's asleep, so it's ready when you press Play.\nBoth need Wake-on-LAN enabled on the PC.")
                    }

                    Section("Library") {
                        NavigationLink(tag: "hidden", selection: $route) {
                            HiddenGamesView(model: model)
                        } label: {
                            HStack {
                                Label("Hidden Games", systemImage: "eye.slash")
                                Spacer()
                                Text("\(model.hiddenGames.count)").foregroundStyle(.secondary)
                            }
                        }
                        .settingsFocus("set-hidden", scope: "settings") { route = "hidden" }
                    }

                    Section("Accounts") {
                        NavigationLink(tag: "steam", selection: $route) {
                            SteamSettingsView()
                        } label: {
                            SteamSettingsRow()
                        }
                        .settingsFocus("set-steam", scope: "settings") { route = "steam" }
                    }

                    Section("Appearance") {
                        NavigationLink(tag: "artwork", selection: $route) {
                            ArtworkSettingsView(model: model)
                        } label: {
                            HStack {
                                Label("Game Artwork", systemImage: "photo.on.rectangle.angled")
                                Spacer()
                                Text(model.artworkConfigured ? "SteamGridDB" : "Not set up")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .settingsFocus("set-artwork", scope: "settings") { route = "artwork" }
                    }

                    Section {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(version).foregroundStyle(.secondary)
                        }
                        Text("Starlight is based on Moonlight by the Moonlight Game Streaming Project, licensed under the GNU GPL v3.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("About")
                    }
                }
                .modifier(FocusScrollFollower(proxy: proxy))
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .starlightStatusToolbar()
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Hidden games

struct HiddenGamesView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.dismiss) private var dismiss
    private let scope = "settings-hidden"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    if model.hiddenGames.isEmpty {
                        Text("No hidden games.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.hiddenGames) { game in
                        HStack(spacing: 12) {
                            ArtworkImage(path: game.gridPath, fallbackText: game.name)
                                .frame(width: 40, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(game.name)
                                .lineLimit(2)
                            Spacer()
                            Button("Show") { model.action("hide", game) }
                                .buttonStyle(.bordered)
                        }
                        .settingsFocus("hidden-\(game.id)", scope: scope) { model.action("hide", game) }
                    }
                } footer: {
                    Text("Hidden games don't appear on Home, in the Library or in Search. Tap Show (or press ✕) to bring one back.\(model.currentHost.map { " Showing games on \($0.name)." } ?? "")")
                }
            }
            .modifier(FocusScrollFollower(proxy: proxy))
        }
        .navigationTitle("Hidden Games")
        .settingsScreen(scope, dismiss: dismiss)
    }
}

// MARK: - PC detail

struct HostDetailView: View {
    @ObservedObject var model: HomeModel
    let hostId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    /// Controller: Remove PC needs a second ✕ (dialogs can't be driven by a controller)
    @State private var removeArmed = false
    @ObservedObject private var focus = GameFocus.shared

    private var host: HostItem? { model.hosts.first { $0.id == hostId } }
    private let scope = "settings-pc"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let host = host {
                    Section {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(host.paired ? (host.online ? "Online" : "Offline") : "Not paired")
                                .foregroundStyle(.secondary)
                        }
                        if !host.address.isEmpty {
                            HStack {
                                Text("Address")
                                Spacer()
                                Text(host.address).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        if !host.paired {
                            Button { model.hostAction("pair", host) } label: {
                                Label("Pair", systemImage: "link")
                            }
                            .settingsFocus("pc-pair", scope: scope) { model.hostAction("pair", host) }
                        } else {
                            if host.id != model.selectedHost {
                                Button { model.onSelectHost?(host.id) } label: {
                                    Label("Use This PC", systemImage: "checkmark.circle")
                                }
                                .settingsFocus("pc-use", scope: scope) { model.onSelectHost?(host.id) }
                            }
                            ProgressActionButton(title: "Refresh Games", symbol: "arrow.clockwise",
                                                 busy: host.refreshing, failed: host.refreshFailed,
                                                 focusID: "pc-refresh", scope: scope) {
                                model.hostAction("refresh", host)
                            }
                        }
                        if !host.online {
                            Button { model.hostAction("wake", host) } label: {
                                Label("Wake PC", systemImage: "power")
                            }
                            .settingsFocus("pc-wake", scope: scope) { model.hostAction("wake", host) }
                        }
                        Button { model.hostAction("testNetwork", host) } label: {
                            Label("Test Network", systemImage: "network")
                        }
                        .settingsFocus("pc-test", scope: scope) { model.hostAction("testNetwork", host) }
                    }

                    Section {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label(removeArmed ? "Press again to remove \(host.name)" : "Remove PC", systemImage: "trash")
                        }
                        .settingsFocus("pc-remove", scope: scope) {
                            if removeArmed {
                                model.hostAction("remove", host)
                            } else {
                                removeArmed = true
                            }
                        }
                    }
                } else {
                    Text("This PC was removed.")
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(FocusScrollFollower(proxy: proxy))
        }
        .navigationTitle(host?.name ?? "PC")
        .settingsScreen(scope, dismiss: dismiss)
        .onChange(of: focus.focusedID) { id in
            if id != "pc-remove" { removeArmed = false }
        }
        .confirmationDialog("Remove \(host?.name ?? "this PC")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove PC", role: .destructive) {
                if let host = host { model.hostAction("remove", host) }
            }
        } message: {
            Text("You'll need to pair again to stream from it.")
        }
    }
}

// MARK: - Artwork settings

struct ArtworkSettingsView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var confirmRemove = false
    @State private var removeArmed = false
    @FocusState private var keyFocused: Bool
    @ObservedObject private var focus = GameFocus.shared
    private let scope = "settings-artwork"

    private func saveKey() {
        model.onArtworkCommand?("save", key)
        key = ""
    }

    private func redownload() {
        SteamOnlyArtwork.shared.reset()
        model.onArtworkCommand?("redownload", "")
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    SecureField(model.artworkConfigured ? "New API key (optional)" : "SteamGridDB API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyFocused)
                        .settingsFocus("art-key", scope: scope) { keyFocused = true }
                    ProgressActionButton(title: model.artworkConfigured ? "Download Missing Artwork" : "Save Key & Download",
                                         symbol: "arrow.down.circle",
                                         busy: model.artworkBusy, failed: model.artworkFailed,
                                         enabled: model.artworkConfigured || !key.isEmpty,
                                         focusID: "art-save", scope: scope, action: saveKey)
                } header: {
                    Text("SteamGridDB")
                } footer: {
                    Text(model.artworkConfigured
                         ? "Key saved (…\(model.artworkKeySuffix)). New games get artwork automatically."
                         : "Steam games use Steam's own artwork without a key. A steamgriddb.com key fills in what Steam doesn't have, covers games that aren't on Steam and enables Edit Artwork. Sign in there, open Preferences → API, generate a key and paste it here. It's stored only in this device's Keychain.")
                }

                Section {
                    ProgressActionButton(title: "Re-download All Artwork", symbol: "arrow.triangle.2.circlepath",
                                         busy: model.artworkBusy, failed: model.artworkFailed,
                                         focusID: "art-redownload", scope: scope, action: redownload)
                } footer: {
                    Text("For each image: your choice in Edit Artwork, then Steam's artwork, then SteamGridDB (by Steam appid, or by name for games that aren't on Steam).")
                }

                if model.artworkConfigured {
                    Section {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label(removeArmed ? "Press again to remove" : "Remove Key & Artwork", systemImage: "trash")
                        }
                        .settingsFocus("art-remove", scope: scope) {
                            if removeArmed {
                                SteamOnlyArtwork.shared.reset()
                                model.onArtworkCommand?("remove", "")
                                removeArmed = false
                            } else {
                                removeArmed = true
                            }
                        }
                    }
                }
            }
            .modifier(FocusScrollFollower(proxy: proxy))
        }
        .navigationTitle("Game Artwork")
        .onChange(of: keyFocused) { focus.textEditing = $0 }
        .settingsScreen(scope, dismiss: dismiss)
        .onChange(of: focus.focusedID) { id in
            if id != "art-remove" { removeArmed = false }
        }
        .confirmationDialog("Remove the SteamGridDB key and downloaded artwork?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                SteamOnlyArtwork.shared.reset()
                model.onArtworkCommand?("remove", "")
            }
        }
    }
}

// MARK: - Stream settings

/// Mirrors Moonlight's stream settings. Keys exchanged with Objective-C:
/// width, height, framerate, bitrate (kbps), onscreenControls (0-3), codec (0 auto, 1 H.264, 2 HEVC, 3 AV1),
/// absoluteTouch, optimizeGames, multiController, swapABXY, audioOnPC, hdr, framePacing, btMouse, statsOverlay,
/// plus read-only resolutions ([{label, width, height}]) and maxFramerate.
struct StreamSettingsView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var customField: Int?
    private let scope = "settings-stream"

    /// Next / previous value in a list (wraps around for ✕)
    private func step<T: Equatable>(_ value: inout T, in options: [T], by delta: Int, wrap: Bool = false) {
        guard let index = options.firstIndex(of: value) else { value = options.first ?? value; return }
        var next = index + delta
        if wrap { next = (next + options.count) % options.count }
        next = min(max(next, 0), options.count - 1)
        value = options[next]
    }

    private var framerates: [Int] { maxFramerate >= 120 ? [30, 60, 120] : [30, 60] }

    @State private var loaded = false
    @State private var resolutions: [ResolutionOption] = []
    @State private var resolutionIndex = 0
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var framerate = 60
    @State private var maxFramerate = 60
    @State private var bitrateMbps: Double = 20
    @State private var onscreenControls = 1
    @State private var codec = 0
    @State private var absoluteTouch = false
    @State private var optimizeGames = true
    @State private var multiController = true
    @State private var swapABXY = false
    @State private var audioOnPC = false
    @State private var hdr = false
    @State private var framePacing = false
    @State private var btMouse = false
    @State private var statsOverlay = false

    struct ResolutionOption: Hashable {
        let label: String
        let width: Int
        let height: Int
    }

    private var customIndex: Int { resolutions.count }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section("Video") {
                Picker("Resolution", selection: $resolutionIndex) {
                    ForEach(Array(resolutions.enumerated()), id: \.offset) { index, res in
                        Text("\(res.label) · \(res.width)×\(res.height)").tag(index)
                    }
                    Text("Custom").tag(customIndex)
                }
                .settingsFocus("st-res", scope: scope, adjust: { step(&resolutionIndex, in: Array(0...customIndex), by: $0) }) {
                    step(&resolutionIndex, in: Array(0...customIndex), by: 1, wrap: true)
                }
                if resolutionIndex == customIndex {
                    HStack {
                        TextField("Width", text: $customWidth).keyboardType(.numberPad)
                            .focused($customField, equals: 0)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $customHeight).keyboardType(.numberPad)
                            .focused($customField, equals: 1)
                    }
                    .settingsFocus("st-custom", scope: scope) { customField = 0 }
                }
                Picker("Frame Rate", selection: $framerate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    if maxFramerate >= 120 { Text("120 FPS").tag(120) }
                }
                .pickerStyle(.segmented)
                .settingsFocus("st-fps", scope: scope, adjust: { step(&framerate, in: framerates, by: $0) }) {
                    step(&framerate, in: framerates, by: 1, wrap: true)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(String(format: "%.1f Mbps", bitrateMbps)).foregroundStyle(.secondary)
                    }
                    Slider(value: $bitrateMbps, in: 0.5...150, step: 0.5)
                }
                .settingsFocus("st-bitrate", scope: scope, adjust: { delta in
                    bitrateMbps = min(150, max(0.5, (bitrateMbps + Double(delta)).rounded()))
                }) {}
                Picker("Video Codec", selection: $codec) {
                    Text("Automatic").tag(0)
                    Text("H.264").tag(1)
                    Text("HEVC").tag(2)
                    Text("AV1").tag(3)
                }
                .settingsFocus("st-codec", scope: scope, adjust: { step(&codec, in: [0, 1, 2, 3], by: $0) }) {
                    step(&codec, in: [0, 1, 2, 3], by: 1, wrap: true)
                }
                switchRow("HDR", $hdr, id: "st-hdr")
                switchRow("Smoothest Video (frame pacing)", $framePacing, id: "st-pacing")
            }

            Section("Controls") {
                Picker("Touch Mode", selection: $absoluteTouch) {
                    Text("Touchpad").tag(false)
                    Text("Touchscreen").tag(true)
                }
                .pickerStyle(.segmented)
                .settingsFocus("st-touch", scope: scope, adjust: { absoluteTouch = $0 > 0 }) { absoluteTouch.toggle() }
                Picker("On-Screen Controls", selection: $onscreenControls) {
                    Text("Off").tag(0)
                    Text("Auto").tag(1)
                    Text("Simple").tag(2)
                    Text("Full").tag(3)
                }
                .settingsFocus("st-osc", scope: scope, adjust: { step(&onscreenControls, in: [0, 1, 2, 3], by: $0) }) {
                    step(&onscreenControls, in: [0, 1, 2, 3], by: 1, wrap: true)
                }
                switchRow("Multi-Controller Mode", $multiController, id: "st-multi")
                switchRow("Swap A/B and X/Y Buttons", $swapABXY, id: "st-swap")
                switchRow("Bluetooth Mouse Support", $btMouse, id: "st-mouse")
            }

            Section("Host") {
                switchRow("Optimize Game Settings", $optimizeGames, id: "st-optimize")
                switchRow("Play Audio on PC", $audioOnPC, id: "st-audio")
                switchRow("Statistics Overlay", $statsOverlay, id: "st-stats")
            }
        }
        .modifier(FocusScrollFollower(proxy: proxy))
        }
        .navigationTitle("Stream Settings")
        .onChange(of: customField) { GameFocus.shared.textEditing = $0 != nil }
        .settingsScreen(scope, dismiss: dismiss)
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .onChange(of: resolutionIndex) { _ in save() }
        .onChange(of: framerate) { _ in save() }
        .onChange(of: codec) { _ in save() }
        .onChange(of: hdr) { _ in save() }
        .onChange(of: framePacing) { _ in save() }
        .onChange(of: absoluteTouch) { _ in save() }
        .onChange(of: onscreenControls) { _ in save() }
        .onChange(of: multiController) { _ in save() }
        .onChange(of: swapABXY) { _ in save() }
        .onChange(of: btMouse) { _ in save() }
        .onChange(of: optimizeGames) { _ in save() }
        .onChange(of: audioOnPC) { _ in save() }
        .onChange(of: statsOverlay) { _ in save() }
    }

    /// A switch row: ✕ flips it, ← off, → on
    private func switchRow(_ title: String, _ value: Binding<Bool>, id: String) -> some View {
        Toggle(title, isOn: value)
            .settingsFocus(id, scope: scope, adjust: { value.wrappedValue = $0 > 0 }) { value.wrappedValue.toggle() }
    }

    private func load() {
        guard !loaded, let settings = model.settingsProvider?() else { return }
        let list = (settings["resolutions"] as? [[String: Any]] ?? []).compactMap { dict -> ResolutionOption? in
            guard let label = dict["label"] as? String,
                  let w = (dict["width"] as? NSNumber)?.intValue,
                  let h = (dict["height"] as? NSNumber)?.intValue else { return nil }
            return ResolutionOption(label: label, width: w, height: h)
        }
        resolutions = list
        let width = (settings["width"] as? NSNumber)?.intValue ?? 1920
        let height = (settings["height"] as? NSNumber)?.intValue ?? 1080
        if let match = list.firstIndex(where: { $0.width == width && $0.height == height }) {
            resolutionIndex = match
        } else {
            resolutionIndex = list.count
            customWidth = "\(width)"
            customHeight = "\(height)"
        }
        maxFramerate = (settings["maxFramerate"] as? NSNumber)?.intValue ?? 60
        framerate = (settings["framerate"] as? NSNumber)?.intValue ?? 60
        bitrateMbps = Double((settings["bitrate"] as? NSNumber)?.intValue ?? 20000) / 1000.0
        onscreenControls = (settings["onscreenControls"] as? NSNumber)?.intValue ?? 1
        codec = (settings["codec"] as? NSNumber)?.intValue ?? 0
        absoluteTouch = (settings["absoluteTouch"] as? NSNumber)?.boolValue ?? false
        optimizeGames = (settings["optimizeGames"] as? NSNumber)?.boolValue ?? true
        multiController = (settings["multiController"] as? NSNumber)?.boolValue ?? true
        swapABXY = (settings["swapABXY"] as? NSNumber)?.boolValue ?? false
        audioOnPC = (settings["audioOnPC"] as? NSNumber)?.boolValue ?? false
        hdr = (settings["hdr"] as? NSNumber)?.boolValue ?? false
        framePacing = (settings["framePacing"] as? NSNumber)?.boolValue ?? false
        btMouse = (settings["btMouse"] as? NSNumber)?.boolValue ?? false
        statsOverlay = (settings["statsOverlay"] as? NSNumber)?.boolValue ?? false
        // Let the onChange handlers fired by the assignments above pass before saving is allowed
        DispatchQueue.main.async { loaded = true }
    }

    private func save() {
        guard loaded else { return }
        var width = 1920
        var height = 1080
        if resolutionIndex < resolutions.count {
            width = resolutions[resolutionIndex].width
            height = resolutions[resolutionIndex].height
        } else if let w = Int(customWidth), let h = Int(customHeight), w >= 256, h >= 256 {
            width = w
            height = h
        } else {
            return
        }
        model.onSaveSettings?([
            "width": width,
            "height": height,
            "framerate": framerate,
            "bitrate": Int(bitrateMbps * 1000),
            "onscreenControls": onscreenControls,
            "codec": codec,
            "absoluteTouch": absoluteTouch,
            "optimizeGames": optimizeGames,
            "multiController": multiController,
            "swapABXY": swapABXY,
            "audioOnPC": audioOnPC,
            "hdr": hdr,
            "framePacing": framePacing,
            "btMouse": btMouse,
            "statsOverlay": statsOverlay
        ])
    }
}


// MARK: - Buttons that start a refresh / download

/// A Settings button for work that takes a while (refresh, download), all with system pieces:
/// on tap the icon bounces with a light haptic; while working a spinner sits on the right and the
/// button is disabled; at the end the icon turns into ✓ (or a warning) for two seconds with a
/// success (or error) haptic.
struct ProgressActionButton: View {
    let title: String
    let symbol: String
    /// The work is running (reported by the app)
    let busy: Bool
    /// The last run failed
    let failed: Bool
    var enabled = true
    let focusID: String
    let scope: String
    let action: () -> Void

    enum Outcome { case success, failure }
    @State private var taps = 0
    @State private var pending = false
    @State private var sawBusy = false
    @State private var outcome: Outcome?

    private var working: Bool { busy || pending }

    private func trigger() {
        guard enabled, !working else { return }
        taps += 1
        outcome = nil
        pending = true
        sawBusy = false
        action()
        // If the app never reports work (nothing to do), stop the spinner quietly
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if pending && !sawBusy && !busy { pending = false }
        }
    }

    private func finish() {
        pending = false
        outcome = failed ? .failure : .success
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { outcome = nil }
        }
    }

    private var iconName: String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case nil: return symbol
        }
    }

    var body: some View {
        Button(action: trigger) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: iconName)
                        .foregroundStyle(outcome == .success ? Color.green : outcome == .failure ? Color.orange : Color.accentColor)
                        .modifier(ActionSymbolEffects(taps: taps, outcome: outcome))
                }
                Spacer()
                if working {
                    ProgressView()
                        .transition(.opacity)
                }
            }
            .animation(.default, value: working)
        }
        .disabled(!enabled || working)
        .settingsFocus(focusID, scope: scope) { trigger() }
        .onChange(of: busy) { isBusy in
            if isBusy {
                sawBusy = true
            } else if sawBusy || pending {
                finish()
            }
        }
    }
}

/// iOS 17+: the symbol bounces on tap and swaps with the system animation; haptics follow the result
private struct ActionSymbolEffects: ViewModifier {
    let taps: Int
    let outcome: ProgressActionButton.Outcome?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: taps)
                .sensoryFeedback(.impact(weight: .light), trigger: taps)
                .sensoryFeedback(trigger: outcome) { _, new in
                    switch new {
                    case .success: return .success
                    case .failure: return .error
                    case nil: return nil
                    }
                }
        } else {
            content
        }
    }
}
