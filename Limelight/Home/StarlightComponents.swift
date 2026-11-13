//
//  StarlightComponents.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Status cluster

/// Clock, game controller, network and battery. iPhone hides the system status bar in landscape,
/// so the app shows its own (like game consoles and Backbone do), drawn with SF Symbols.
final class DeviceStatus: ObservableObject {
    static let shared = DeviceStatus()

    enum Network { case wifi, cellular, wired, none }
    enum ControllerBrand { case playstation, xbox, other }

    @Published var now = Date()
    @Published var batteryLevel: Float = -1
    @Published var charging = false
    @Published var network: Network = .none
    @Published var controllerConnected = false
    @Published var controllerBattery: Float?
    @Published var controllerBrand: ControllerBrand = .other

    private let monitor = NWPathMonitor()
    private var timer: Timer?

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        refreshControllers()

        monitor.pathUpdateHandler = { [weak self] path in
            let network: Network
            if path.status != .satisfied {
                network = .none
            } else if path.usesInterfaceType(.wifi) {
                network = .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                network = .wired
            } else if path.usesInterfaceType(.cellular) {
                network = .cellular
            } else {
                network = .wifi
            }
            DispatchQueue.main.async { self?.network = network }
        }
        monitor.start(queue: DispatchQueue(label: "starlight.network-status"))

        let center = NotificationCenter.default
        center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() }
        center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() }
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshControllers() }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshControllers() }

        // Clock and controller battery (no change notifications for the latter)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.refreshControllers()
        }
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        charging = state == .charging || state == .full
    }

    private func refreshControllers() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil || $0.microGamepad != nil }
        controllerConnected = !controllers.isEmpty
        let category = (controllers.first?.productCategory ?? "").lowercased()
        if category.contains("dualsense") || category.contains("dualshock") || category.contains("playstation") {
            controllerBrand = .playstation
        } else if category.contains("xbox") {
            controllerBrand = .xbox
        } else {
            controllerBrand = .other
        }
        if let level = controllers.compactMap({ $0.battery?.batteryLevel }).first, level > 0 {
            controllerBattery = level
        } else {
            controllerBattery = nil
        }
    }
}

struct StatusCluster: View {
    @ObservedObject private var status = DeviceStatus.shared

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: status.now)
    }

    private var batterySymbol: String {
        if status.charging { return "battery.100.bolt" }
        let level = status.batteryLevel
        if level < 0 { return "battery.100" }
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var networkSymbol: String {
        switch status.network {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .none: return "wifi.slash"
        }
    }

    private var controllerSymbol: String {
        switch status.controllerBrand {
        case .playstation: return "playstation.logo"
        case .xbox: return "xbox.logo"
        case .other: return "gamecontroller.fill"
        }
    }

    var body: some View {
        // Same layout as console-style launchers: clock, then controller, network and battery icons
        HStack(spacing: 12) {
            Text(timeText)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            if status.controllerConnected {
                Image(systemName: controllerSymbol)
                    .accessibilityLabel(status.controllerBattery.map { "Controller connected, battery \(Int(($0 * 100).rounded())) percent" } ?? "Controller connected")
            }
            Image(systemName: networkSymbol)
                .accessibilityLabel(status.network == .none ? "No network" : "Network connected")
            Image(systemName: batterySymbol)
                .foregroundStyle(!status.charging && status.batteryLevel >= 0 && status.batteryLevel < 0.2 ? Color.red : Color.white)
                .accessibilityLabel(status.batteryLevel >= 0 ? "Battery \(Int((status.batteryLevel * 100).rounded())) percent" : "Battery")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .modifier(ToolbarItemGlass())
    }
}

/// iOS 26 wraps navigation bar items in Liquid Glass itself; earlier versions get a material capsule
struct ToolbarItemGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Shared pieces

struct ArtworkImage: View {
    let path: String?
    let fallbackText: String
    var remoteURL: URL? = nil

    var body: some View {
        if let image = ArtworkCache.shared.image(path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = remoteURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Group {
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(fallbackText)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
            }
        }
    }
}

/// The game options shown in the ••• menu and on long-press
struct GameMenuItems: View {
    let game: GameItem
    @ObservedObject var model: HomeModel

    var body: some View {
        Button { model.action("pin", game) } label: {
            Label(game.pinned ? "Unpin" : "Pin", systemImage: game.pinned ? "pin.slash" : "pin")
        }
        Button { model.action("copyLink", game) } label: {
            Label("Copy Shortcut Link", systemImage: "link")
        }
        Button { model.action("saveIcon", game) } label: {
            Label("Save Icon to Photos", systemImage: "photo")
        }
        Button { model.editingGame = game } label: {
            Label("Edit Artwork…", systemImage: "photo.on.rectangle.angled")
        }
        Button { model.action("hide", game) } label: {
            Label(game.hidden ? "Show Game" : "Hide Game", systemImage: game.hidden ? "eye" : "eye.slash")
        }
        if game.running {
            Button(role: .destructive) { model.action("quit", game) } label: {
                Label("Quit Game", systemImage: "xmark.circle")
            }
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.hosts.isEmpty ? "desktopcomputer" : "gamecontroller")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(starlightGold)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if model.hosts.isEmpty {
                Button { model.command("addHost") } label: {
                    Label("Add PC", systemImage: "plus")
                }
                .primaryGlassButton()
            } else if let host = model.currentHost, !host.paired {
                Button { model.onSelectHost?(host.id) } label: {
                    Label("Pair with \(host.name)", systemImage: "link")
                }
                .primaryGlassButton()
            } else if let host = model.currentHost {
                Button { model.hostAction("refresh", host) } label: {
                    Label("Refresh Games", systemImage: "arrow.clockwise")
                }
                .primaryGlassButton()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if model.hosts.isEmpty { return "No PCs yet" }
        guard let host = model.currentHost else { return "Choose a PC" }
        if host.permissionDenied { return "\(host.name) isn't sharing its games" }
        return host.paired ? "No games found" : "\(host.name) isn't paired"
    }

    private var message: String {
        if model.hosts.isEmpty { return "Starlight finds PCs running Sunshine or Vibepollo on your network. You can also add one by address." }
        guard let host = model.currentHost else { return "Pick a PC from the menu at the top." }
        if host.permissionDenied {
            return "On the PC, open the Vibepollo Web UI, go to Client Management, select this iPhone and turn on \u{201C}List applications\u{201D}. Then refresh."
        }
        return host.paired ? "Refresh to load the games from \(host.name)." : "Pair once to see and stream its games."
    }
}
