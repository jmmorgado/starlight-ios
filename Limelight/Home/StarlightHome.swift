//
//  StarlightHome.swift
//  Starlight
//
//  The Starlight UI: a SwiftUI layer on top of MainFrameViewController.
//  MainFrameViewController keeps doing the Moonlight work (discovery, pairing,
//  app lists, streaming) and pushes plain dictionaries here; user actions go
//  back through the closures on StarlightHomeController.
//
//  Liquid Glass is used on iOS 26 (glassEffect, glass button styles, the system
//  tab bar); older versions fall back to materials.
//

import SwiftUI
import UIKit

// MARK: - Bridge used from Objective-C

@objc(StarlightHomeController)
final class StarlightHomeController: NSObject {
    private let model = HomeModel()
    private lazy var hosting: UIHostingController<HomeRootView> = {
        let controller = UIHostingController(rootView: HomeRootView(model: model))
        controller.view.backgroundColor = .black
        controller.overrideUserInterfaceStyle = .dark
        return controller
    }()

    @objc var viewController: UIViewController { hosting }

    /// (hostUUID) – choose a PC (pairs it if needed)
    @objc var onSelectHost: ((String) -> Void)? {
        didSet { model.onSelectHost = onSelectHost }
    }
    /// (hostUUID, appId) – start or resume streaming
    @objc var onLaunchApp: ((String, String) -> Void)? {
        didSet { model.onLaunchApp = onLaunchApp }
    }
    /// (action, hostUUID, appId): "pin", "copyLink", "saveIcon", "hide", "quit"
    @objc var onAppAction: ((String, String, String) -> Void)? {
        didSet { model.onAppAction = onAppAction }
    }
    /// (action, hostUUID): "refresh", "wake", "testNetwork", "remove", "pair", "toggleHidden"
    @objc var onHostAction: ((String, String) -> Void)? {
        didSet { model.onHostAction = onHostAction }
    }
    /// (command): "addHost"
    @objc var onCommand: ((String) -> Void)? {
        didSet { model.onCommand = onCommand }
    }
    /// (command, apiKey): "save", "redownload", "remove"
    @objc var onArtworkCommand: ((String, String) -> Void)? {
        didSet { model.onArtworkCommand = onArtworkCommand }
    }
    /// Current stream settings (see StreamSettingsView for the keys)
    @objc var settingsProvider: (() -> [String: Any])? {
        didSet { model.settingsProvider = settingsProvider }
    }
    @objc var onSaveSettings: (([String: Any]) -> Void)? {
        didSet { model.onSaveSettings = onSaveSettings }
    }
    /// (action, params, reply) for the Edit Artwork screen: "info", "search", "options", "setMatch", "setImage"
    @objc var artworkRequest: ((String, [String: Any], @escaping ([String: Any]) -> Void) -> Void)? {
        didSet { model.artworkRequest = artworkRequest }
    }

    @objc(updateWithHosts:selectedHost:apps:artwork:)
    func update(hosts: [[String: Any]], selectedHost: String?, apps: [[String: Any]], artwork: [String: Any]) {
        let hostItems = hosts.compactMap(HostItem.init)
        let gameItems = apps.compactMap(GameItem.init)
        if model.hosts != hostItems { model.hosts = hostItems }
        if model.selectedHost != selectedHost { model.selectedHost = selectedHost }
        if model.games != gameItems {
            model.games = gameItems
            ArtworkCache.shared.removeAll()
        }
        let configured = artwork["configured"] as? Bool ?? false
        let suffix = artwork["keySuffix"] as? String ?? ""
        if model.artworkConfigured != configured { model.artworkConfigured = configured }
        if model.artworkKeySuffix != suffix { model.artworkKeySuffix = suffix }
        if let featured = model.featuredId, !gameItems.contains(where: { $0.id == featured }) {
            model.featuredId = nil
        }
    }
}

// MARK: - Model

struct HostItem: Identifiable, Equatable {
    let id: String
    let name: String
    let online: Bool
    let paired: Bool
    let showHidden: Bool
    let address: String

    init?(_ dict: [String: Any]) {
        guard let uuid = dict["uuid"] as? String else { return nil }
        id = uuid
        name = dict["name"] as? String ?? "PC"
        online = dict["online"] as? Bool ?? false
        paired = dict["paired"] as? Bool ?? false
        showHidden = dict["showHidden"] as? Bool ?? false
        address = dict["address"] as? String ?? ""
    }
}

struct GameItem: Identifiable, Equatable {
    let id: String
    let host: String
    let app: String
    let name: String
    let hostName: String
    let running: Bool
    let pinIndex: Int?
    let hidden: Bool
    let gridPath: String?
    let heroPath: String?
    let logoPath: String?
    let widePath: String?
    let lastPlayed: Date?
    let artStamp: Double

    var pinned: Bool { pinIndex != nil }

    init?(_ dict: [String: Any]) {
        guard let host = dict["host"] as? String,
              let app = dict["app"] as? String,
              let name = dict["name"] as? String else { return nil }
        self.host = host
        self.app = app
        self.name = name
        id = "\(host)|\(app)"
        hostName = dict["hostName"] as? String ?? ""
        running = dict["running"] as? Bool ?? false
        hidden = dict["hidden"] as? Bool ?? false
        if let index = dict["pinIndex"] as? Int, index >= 0 {
            pinIndex = index
        } else {
            pinIndex = nil
        }
        gridPath = GameItem.nonEmpty(dict["gridPath"])
        heroPath = GameItem.nonEmpty(dict["heroPath"])
        logoPath = GameItem.nonEmpty(dict["logoPath"])
        widePath = GameItem.nonEmpty(dict["widePath"])
        artStamp = (dict["artStamp"] as? NSNumber)?.doubleValue ?? 0
        if let seconds = dict["lastPlayed"] as? Double, seconds > 0 {
            lastPlayed = Date(timeIntervalSince1970: seconds)
        } else {
            lastPlayed = nil
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

final class HomeModel: ObservableObject {
    @Published var hosts: [HostItem] = []
    @Published var selectedHost: String?
    @Published var games: [GameItem] = []
    @Published var featuredId: String?
    /// Which row the featured game was picked from, so only that card is outlined
    @Published var featuredRow = "continue"
    @Published var editingGame: GameItem?
    @Published var artworkConfigured = false
    @Published var artworkKeySuffix = ""

    var onSelectHost: ((String) -> Void)?
    var onLaunchApp: ((String, String) -> Void)?
    var onAppAction: ((String, String, String) -> Void)?
    var onHostAction: ((String, String) -> Void)?
    var onCommand: ((String) -> Void)?
    var onArtworkCommand: ((String, String) -> Void)?
    var settingsProvider: (() -> [String: Any])?
    var onSaveSettings: (([String: Any]) -> Void)?
    var artworkRequest: ((String, [String: Any], @escaping ([String: Any]) -> Void) -> Void)?

    var currentHost: HostItem? { hosts.first { $0.id == selectedHost } }
    var pairedHosts: [HostItem] { hosts.filter { $0.paired } }
    var networkHosts: [HostItem] { hosts.filter { !$0.paired } }

    private func pinnedFirst(_ a: GameItem, _ b: GameItem) -> Bool? {
        switch (a.pinIndex, b.pinIndex) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }

    /// Pinned games first (in pin order), then the running game, then most recently played
    var continueGames: [GameItem] {
        games.filter { !$0.hidden }.sorted { a, b in
            if let pinned = pinnedFirst(a, b) { return pinned }
            if a.running != b.running { return a.running }
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Pinned games first, then alphabetical (hidden games only when the PC shows them)
    var libraryGames: [GameItem] {
        let showHidden = currentHost?.showHidden ?? false
        return games.filter { showHidden || !$0.hidden }.sorted { a, b in
            if let pinned = pinnedFirst(a, b) { return pinned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The game the user tapped, else the running game, else the first of Continue Playing
    var featured: GameItem? {
        if let id = featuredId, let game = games.first(where: { $0.id == id }) { return game }
        return games.first(where: { $0.running }) ?? continueGames.first
    }

    func launch(_ game: GameItem) { onLaunchApp?(game.host, game.app) }
    func action(_ name: String, _ game: GameItem) { onAppAction?(name, game.host, game.app) }
    func hostAction(_ name: String, _ host: HostItem) { onHostAction?(name, host.id) }
    func command(_ name: String) { onCommand?(name) }
}

// MARK: - Artwork loading

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(_ path: String?) -> UIImage? {
        guard let path = path else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}

private let starlightGold = Color(red: 0.86, green: 0.72, blue: 0.42)

// MARK: - Glass helpers (Liquid Glass on iOS 26, materials before)

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

// MARK: - Root

struct HomeRootView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        TabView {
            HomeTab(model: model)
                .tabItem { Label("Home", systemImage: "house.fill") }
            LibraryTab(model: model)
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(starlightGold)
        .preferredColorScheme(.dark)
        .sheet(item: $model.editingGame) { game in
            ArtworkEditorView(model: model, game: game)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Shared pieces

struct HostMenu: View {
    @ObservedObject var model: HomeModel
    /// In a navigation bar iOS 26 already wraps the item in Liquid Glass, so don't add a second capsule
    var inToolbar = false

    var body: some View {
        Menu {
            if !model.pairedHosts.isEmpty {
                Section("Your PCs") {
                    ForEach(model.pairedHosts) { host in
                        Button {
                            model.onSelectHost?(host.id)
                        } label: {
                            Label(host.name + (host.online ? "" : " · offline"),
                                  systemImage: host.id == model.selectedHost ? "checkmark" : "desktopcomputer")
                        }
                    }
                }
            }
            if !model.networkHosts.isEmpty {
                Section("On Your Network") {
                    ForEach(model.networkHosts) { host in
                        Button {
                            model.onSelectHost?(host.id)
                        } label: {
                            Label("\(host.name) · tap to pair", systemImage: "link")
                        }
                    }
                }
            }
            Section {
                if let host = model.currentHost, host.paired {
                    Button { model.hostAction("refresh", host) } label: {
                        Label("Refresh Games", systemImage: "arrow.clockwise")
                    }
                }
                Button { model.command("addHost") } label: {
                    Label("Add PC by Address…", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentHost?.name ?? "Choose a PC")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, inToolbar ? 6 : 14)
            .padding(.vertical, inToolbar ? 2 : 8)
            .modifier(HostMenuBackground(inToolbar: inToolbar))
        }
        .accessibilityLabel("Choose PC, current: \(model.currentHost?.name ?? "none")")
    }

    private var statusColor: Color {
        guard let host = model.currentHost else { return .gray }
        if !host.paired { return .orange }
        return host.online ? .green : .gray
    }

    private var statusText: String {
        guard let host = model.currentHost else { return model.hosts.isEmpty ? "No PCs yet" : "Tap to choose" }
        let others = model.hosts.count - 1
        var text = !host.paired ? "Not paired" : (host.online ? "Online" : "Offline")
        if others > 0 { text += " · \(others) more" }
        return text
    }
}

private struct HostMenuBackground: ViewModifier {
    let inToolbar: Bool

    func body(content: Content) -> some View {
        if inToolbar {
            if #available(iOS 26.0, *) {
                content
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        } else {
            content.glassCapsule()
        }
    }
}

struct ArtworkImage: View {
    let path: String?
    let fallbackText: String

    var body: some View {
        if let image = ArtworkCache.shared.image(path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
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
        return host.paired ? "No games found" : "\(host.name) isn't paired"
    }

    private var message: String {
        if model.hosts.isEmpty { return "Starlight finds PCs running Sunshine or Vibepollo on your network. You can also add one by address." }
        guard let host = model.currentHost else { return "Pick a PC from the menu at the top." }
        return host.paired ? "Refresh to load the games from \(host.name)." : "Pair once to see and stream its games."
    }
}

// MARK: - Home tab

struct HomeTab: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 500
            ZStack(alignment: .top) {
                backdrop(size: geo.size)

                if let featured = model.featured {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
                            HostMenu(model: model)

                            FeaturedSection(game: featured, model: model, compact: compact)

                            GameRow(id: "continue", title: "Continue Playing", games: model.continueGames, model: model, compact: compact)

                            GameRow(id: "all", title: "All Games", games: model.libraryGames, model: model, compact: compact)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            HostMenu(model: model)
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        EmptyStateView(model: model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func backdrop(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let featured = model.featured, let hero = ArtworkCache.shared.image(featured.heroPath ?? featured.gridPath) {
                // Fill the whole screen (edge to edge, behind the safe areas) by zooming, never stretching
                Color.clear
                    .overlay(
                        Image(uiImage: hero)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
                    .id(featured.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.45), .black.opacity(0.15)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.9)],
                           startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: model.featured?.id)
    }
}

struct FeaturedSection: View {
    let game: GameItem
    @ObservedObject var model: HomeModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let logo = ArtworkCache.shared.image(game.logoPath) {
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: compact ? 280 : 380, maxHeight: compact ? 70 : 110, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .accessibilityLabel(game.name)
            } else {
                Text(game.name)
                    .font(.system(size: compact ? 30 : 40, weight: .heavy))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }

            HStack(spacing: 8) {
                if game.running {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Running on PC")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassCapsule()
                }
                if game.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(starlightGold)
                        .accessibilityLabel("Pinned")
                }
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(spacing: 10) {
                Button { model.launch(game) } label: {
                    Label(game.running ? "Resume" : "Play", systemImage: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .primaryGlassButton()
                .tint(.white)
                .foregroundStyle(.black)

                if game.running {
                    Button(role: .destructive) { model.action("quit", game) } label: {
                        Label("Quit", systemImage: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .secondaryGlassButton()
                    .tint(.red)
                }

                Menu {
                    GameMenuItems(game: game, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .secondaryGlassButton()
                .accessibilityLabel("Game options")
            }
        }
        .padding(.top, compact ? 4 : 30)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !game.hostName.isEmpty { parts.append(game.hostName) }
        if let last = game.lastPlayed {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Played " + formatter.localizedString(for: last, relativeTo: Date()))
        } else {
            parts.append("Not played yet")
        }
        return parts.joined(separator: " · ")
    }
}

struct GameRow: View {
    let id: String
    let title: String
    let games: [GameItem]
    @ObservedObject var model: HomeModel
    let compact: Bool
    var portrait: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(games) { game in
                        GameCard(game: game,
                                 selected: game.id == model.featured?.id && model.featuredRow == id,
                                 portrait: portrait,
                                 height: portrait ? (compact ? 150 : 180) : (compact ? 84 : 110))
                            .onTapGesture {
                                if game.id == model.featured?.id && model.featuredRow == id {
                                    model.launch(game)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        model.featuredId = game.id
                                        model.featuredRow = id
                                    }
                                }
                            }
                            .contextMenu { GameMenuItems(game: game, model: model) }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }
}

struct GameCard: View {
    let game: GameItem
    let selected: Bool
    let portrait: Bool
    let height: CGFloat

    var body: some View {
        let width = portrait ? height * 2 / 3 : height * 16 / 9
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(path: portrait ? game.gridPath : (game.widePath ?? game.heroPath ?? game.gridPath), fallbackText: game.name)
                .frame(width: width, height: height)
                .clipped()

            // A hand-picked landscape grid already shows the game's name
            if !portrait && game.widePath == nil {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let logo = ArtworkCache.shared.image(game.logoPath) {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: width * 0.6, maxHeight: height * 0.4, alignment: .bottomLeading)
                        .padding(10)
                } else {
                    Text(game.name)
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)
                        .padding(10)
                }
            }

            HStack(spacing: 6) {
                if game.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(starlightGold)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                }
                if game.running {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: width, height: height)
        .opacity(game.hidden ? 0.45 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(0.4), radius: selected ? 10 : 5, y: 4)
        .scaleEffect(selected ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name + (game.running ? ", running" : "") + (game.pinned ? ", pinned" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Library tab

struct LibraryTab: View {
    @ObservedObject var model: HomeModel
    @State private var search = ""

    private var filtered: [GameItem] {
        let all = model.libraryGames
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationView {
            Group {
                if model.games.isEmpty {
                    EmptyStateView(model: model)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)], spacing: 18) {
                            ForEach(filtered) { game in
                                VStack(alignment: .leading, spacing: 6) {
                                    GameCard(game: game, selected: false, portrait: true, height: 180)
                                    Text(game.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: 120)
                                .onTapGesture { model.launch(game) }
                                .contextMenu { GameMenuItems(game: game, model: model) }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HostMenu(model: model, inToolbar: true)
                }
            }
            .searchable(text: $search, prompt: "Search games")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Settings tab

struct SettingsTab: View {
    @ObservedObject var model: HomeModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationView {
            List {
                Section("Streaming") {
                    NavigationLink {
                        StreamSettingsView(model: model)
                    } label: {
                        Label("Stream Settings", systemImage: "slider.horizontal.3")
                    }
                }

                Section("PCs") {
                    ForEach(model.hosts) { host in
                        NavigationLink {
                            HostDetailView(model: model, hostId: host.id)
                        } label: {
                            HStack {
                                Label(host.name, systemImage: "desktopcomputer")
                                Spacer()
                                Text(host.paired ? (host.online ? "Online" : "Offline") : "Not paired")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { model.command("addHost") } label: {
                        Label("Add PC by Address…", systemImage: "plus")
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        ArtworkSettingsView(model: model)
                    } label: {
                        HStack {
                            Label("Game Artwork", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Text(model.artworkConfigured ? "SteamGridDB" : "Not set up")
                                .foregroundStyle(.secondary)
                        }
                    }
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
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - PC detail

struct HostDetailView: View {
    @ObservedObject var model: HomeModel
    let hostId: String
    @State private var confirmRemove = false

    private var host: HostItem? { model.hosts.first { $0.id == hostId } }

    var body: some View {
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
                    } else {
                        if host.id != model.selectedHost {
                            Button { model.onSelectHost?(host.id) } label: {
                                Label("Use This PC", systemImage: "checkmark.circle")
                            }
                        }
                        Button { model.hostAction("refresh", host) } label: {
                            Label("Refresh Games", systemImage: "arrow.clockwise")
                        }
                        Toggle(isOn: Binding(get: { host.showHidden },
                                             set: { _ in model.hostAction("toggleHidden", host) })) {
                            Label("Show Hidden Games", systemImage: "eye")
                        }
                    }
                    if !host.online {
                        Button { model.hostAction("wake", host) } label: {
                            Label("Wake PC", systemImage: "power")
                        }
                    }
                    Button { model.hostAction("testNetwork", host) } label: {
                        Label("Test Network", systemImage: "network")
                    }
                }

                Section {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove PC", systemImage: "trash")
                    }
                }
            } else {
                Text("This PC was removed.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(host?.name ?? "PC")
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
    @State private var key = ""
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                SecureField(model.artworkConfigured ? "New API key (optional)" : "SteamGridDB API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    model.onArtworkCommand?("save", key)
                    key = ""
                } label: {
                    Label(model.artworkConfigured ? "Download Missing Artwork" : "Save Key & Download", systemImage: "arrow.down.circle")
                }
                .disabled(!model.artworkConfigured && key.isEmpty)
            } header: {
                Text("SteamGridDB")
            } footer: {
                Text(model.artworkConfigured
                     ? "Key saved (…\(model.artworkKeySuffix)). New games get artwork automatically."
                     : "Covers, backgrounds, logos and icons come from steamgriddb.com. Sign in there, open Preferences → API, generate a key and paste it here. It's stored only on this device.")
            }

            if model.artworkConfigured {
                Section {
                    Button { model.onArtworkCommand?("redownload", "") } label: {
                        Label("Re-download All Artwork", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove Key & Artwork", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Game Artwork")
        .confirmationDialog("Remove the SteamGridDB key and downloaded artwork?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.onArtworkCommand?("remove", "") }
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
        Form {
            Section("Video") {
                Picker("Resolution", selection: $resolutionIndex) {
                    ForEach(Array(resolutions.enumerated()), id: \.offset) { index, res in
                        Text("\(res.label) · \(res.width)×\(res.height)").tag(index)
                    }
                    Text("Custom").tag(customIndex)
                }
                if resolutionIndex == customIndex {
                    HStack {
                        TextField("Width", text: $customWidth).keyboardType(.numberPad)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $customHeight).keyboardType(.numberPad)
                    }
                }
                Picker("Frame Rate", selection: $framerate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    if maxFramerate >= 120 { Text("120 FPS").tag(120) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(String(format: "%.1f Mbps", bitrateMbps)).foregroundStyle(.secondary)
                    }
                    Slider(value: $bitrateMbps, in: 0.5...150, step: 0.5)
                }
                Picker("Video Codec", selection: $codec) {
                    Text("Automatic").tag(0)
                    Text("H.264").tag(1)
                    Text("HEVC").tag(2)
                    Text("AV1").tag(3)
                }
                Toggle("HDR", isOn: $hdr)
                Toggle("Smoothest Video (frame pacing)", isOn: $framePacing)
            }

            Section("Controls") {
                Picker("Touch Mode", selection: $absoluteTouch) {
                    Text("Touchpad").tag(false)
                    Text("Touchscreen").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("On-Screen Controls", selection: $onscreenControls) {
                    Text("Off").tag(0)
                    Text("Auto").tag(1)
                    Text("Simple").tag(2)
                    Text("Full").tag(3)
                }
                Toggle("Multi-Controller Mode", isOn: $multiController)
                Toggle("Swap A/B and X/Y Buttons", isOn: $swapABXY)
                Toggle("Bluetooth Mouse Support", isOn: $btMouse)
            }

            Section("Host") {
                Toggle("Optimize Game Settings", isOn: $optimizeGames)
                Toggle("Play Audio on PC", isOn: $audioOnPC)
                Toggle("Statistics Overlay", isOn: $statsOverlay)
            }
        }
        .navigationTitle("Stream Settings")
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

// MARK: - Edit artwork (manual SteamGridDB match and images)

struct ArtworkEditorView: View {
    @ObservedObject var model: HomeModel
    let game: GameItem
    @Environment(\.dismiss) private var dismiss

    struct SearchResult: Identifiable, Hashable {
        let id: String
        let name: String
        let year: String
        let verified: Bool
    }

    struct ImageOption: Identifiable, Hashable {
        var id: String { url }
        let url: String
        let thumb: String
    }

    @State private var configured = true
    @State private var matchId = ""
    @State private var matchName = ""
    @State private var term = ""
    @State private var searching = false
    @State private var searchFailed = false
    @State private var results: [SearchResult] = []
    @State private var applyingMatch: String?
    @State private var options: [String: [ImageOption]] = [:]
    @State private var loadingKinds: Set<String> = []
    @State private var chosen: [String: String] = [:]
    @State private var applyingImage: String?

    struct ArtKind: Identifiable {
        var id: String { kind }
        let kind: String
        let title: String
        let aspect: CGFloat
        let footer: String
    }

    private let kinds: [ArtKind] = [
        ArtKind(kind: "hero", title: "Background", aspect: 16.0 / 9.0,
                footer: "Fills the Home screen and the loading screen. Also used for the game cards unless you pick a Landscape image."),
        ArtKind(kind: "wide", title: "Landscape", aspect: 460.0 / 215.0,
                footer: "Optional image for the game cards in Continue Playing and All Games."),
        ArtKind(kind: "grid", title: "Cover", aspect: 2.0 / 3.0,
                footer: "Used in Library."),
        ArtKind(kind: "logo", title: "Logo", aspect: 2.0,
                footer: "Shown over the background and on the game cards."),
        ArtKind(kind: "icon", title: "Icon", aspect: 1.0,
                footer: "Used for Save Icon to Photos and in the Shortcuts app.")
    ]

    var body: some View {
        NavigationView {
            List {
                if !configured {
                    Section {
                        Text("Add your SteamGridDB API key in Settings › Game Artwork first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        HStack {
                            Text("Matched to")
                            Spacer()
                            Text(matchName.isEmpty ? "No match" : matchName)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            TextField("Search SteamGridDB", text: $term)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit(search)
                            if searching {
                                ProgressView()
                            } else {
                                Button("Search", action: search)
                                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if searchFailed {
                            Text("Couldn't reach SteamGridDB. Try again.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { result in
                            Button {
                                applyMatch(result)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name)
                                            .foregroundStyle(.primary)
                                        if !result.year.isEmpty {
                                            Text(result.year)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if applyingMatch == result.id {
                                        ProgressView()
                                    } else if result.id == matchId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(starlightGold)
                                    }
                                }
                            }
                            .disabled(applyingMatch != nil)
                        }
                    } header: {
                        Text("Game")
                    } footer: {
                        Text("Pick the right game if the artwork belongs to a different version or edition. Your choice is kept when artwork is downloaded again.")
                    }

                    ForEach(kinds) { item in
                        Section {
                            imageStrip(kind: item.kind, aspect: item.aspect)
                        } header: {
                            Text(item.title)
                        } footer: {
                            Text(item.footer)
                        }
                    }
                }
            }
            .navigationTitle(game.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func imageStrip(kind: String, aspect: CGFloat) -> some View {
        let height: CGFloat = kind == "grid" ? 150 : (kind == "icon" ? 80 : 90)
        let width = height * aspect
        if loadingKinds.contains(kind) {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(height: height)
        } else if let list = options[kind], !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(list) { option in
                        Button {
                            applyImage(kind: kind, option: option)
                        } label: {
                            ZStack {
                                Color(white: kind == "logo" || kind == "icon" ? 0.18 : 0.12)
                                AsyncImage(url: URL(string: option.thumb)) { phase in
                                    if let image = phase.image {
                                        image.resizable()
                                            .aspectRatio(contentMode: kind == "logo" || kind == "icon" ? .fit : .fill)
                                    } else if phase.error != nil {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ProgressView()
                                    }
                                }
                                .padding(kind == "logo" ? 8 : 0)
                                if applyingImage == option.url {
                                    Color.black.opacity(0.5)
                                    ProgressView()
                                }
                            }
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(chosen[kind] == option.url ? starlightGold : .white.opacity(0.12),
                                            lineWidth: chosen[kind] == option.url ? 3 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingImage != nil)
                        .accessibilityLabel("\(kind) option")
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: height + 8)
        } else {
            Text(matchId.isEmpty ? "Pick a game above first." : "Nothing available.")
                .foregroundStyle(.secondary)
        }
    }

    private func request(_ action: String, _ params: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
        guard let handler = model.artworkRequest else { return }
        handler(action, params, reply)
    }

    private func load() {
        term = game.name
        request("info", ["name": game.name]) { info in
            configured = (info["configured"] as? NSNumber)?.boolValue ?? false
            matchId = info["matchId"] as? String ?? ""
            matchName = info["matchName"] as? String ?? ""
            if configured {
                search()
                loadOptions()
            }
        }
    }

    private func search() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        searchFailed = false
        request("search", ["term": query]) { reply in
            searching = false
            guard let list = reply["results"] as? [[String: Any]] else {
                searchFailed = true
                return
            }
            results = list.compactMap { dict in
                guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                return SearchResult(id: id, name: name, year: dict["year"] as? String ?? "",
                                    verified: (dict["verified"] as? NSNumber)?.boolValue ?? false)
            }
        }
    }

    private func loadOptions() {
        guard !matchId.isEmpty else { return }
        for item in kinds {
            let kind = item.kind
            loadingKinds.insert(kind)
            request("options", ["name": game.name, "kind": kind]) { reply in
                loadingKinds.remove(kind)
                let list = reply["options"] as? [[String: Any]] ?? []
                options[kind] = list.compactMap { dict in
                    guard let url = dict["url"] as? String else { return nil }
                    return ImageOption(url: url, thumb: dict["thumb"] as? String ?? url)
                }
            }
        }
    }

    private func applyMatch(_ result: SearchResult) {
        applyingMatch = result.id
        request("setMatch", ["name": game.name, "gameId": result.id, "gameName": result.name]) { _ in
            applyingMatch = nil
            matchId = result.id
            matchName = result.name
            chosen = [:]
            options = [:]
            loadOptions()
        }
    }

    private func applyImage(kind: String, option: ImageOption) {
        applyingImage = option.url
        request("setImage", ["name": game.name, "kind": kind, "url": option.url]) { reply in
            applyingImage = nil
            if (reply["ok"] as? NSNumber)?.boolValue ?? false {
                chosen[kind] = option.url
            }
        }
    }
}
