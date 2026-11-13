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
//  This file: the Objective-C bridge, the model, the artwork cache and glass helpers.
//  The screens live next to it:
//    StarlightRoot           tab view, toolbar, PC button, search screen
//    StarlightFocus          controller glyphs, focus engine, gamepad input, PC/game panels
//    StarlightComponents     status cluster, artwork image, shared pieces
//    StarlightHomeTab        Home (featured game, rows)
//    StarlightGameDetail     game page and cards
//    StarlightLibrary        Library and Search
//    StarlightSettings       Settings, hidden games, PC detail, artwork and stream settings
//    StarlightArtworkEditor  Edit Artwork (manual SteamGridDB match and images)
//    StarlightStreamMenu     the menu shown over a running stream
//    StarlightSteam          Steam account, games, achievements
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

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

    override init() {
        super.init()
        let homeModel = model
        GamepadInput.shared.handler = { [weak homeModel] event in homeModel?.handlePad(event) }
        // Steam data: refresh when it's more than a few hours old
        Task { @MainActor in SteamManager.shared.refreshIfStale() }
    }

    /// On while the Starlight screens are visible, off during a stream
    @objc func setControllerInputActive(_ active: Bool) {
        GamepadInput.shared.active = active
    }

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
            // Only drop the images of games whose artwork changed (artStamp follows the files' dates)
            let oldStamps = Dictionary(model.games.map { ($0.id, $0.artStamp) }, uniquingKeysWith: { first, _ in first })
            for game in gameItems where oldStamps[game.id].map({ $0 != game.artStamp }) ?? false {
                ArtworkCache.shared.remove([game.gridPath, game.heroPath, game.logoPath])
            }
            model.games = gameItems
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
    let permissionDenied: Bool
    let address: String

    init?(_ dict: [String: Any]) {
        guard let uuid = dict["uuid"] as? String else { return nil }
        id = uuid
        name = dict["name"] as? String ?? "PC"
        online = dict["online"] as? Bool ?? false
        paired = dict["paired"] as? Bool ?? false
        showHidden = dict["showHidden"] as? Bool ?? false
        permissionDenied = dict["permissionDenied"] as? Bool ?? false
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
    let lastPlayed: Date?
    let artStamp: Double
    /// Steam appid, from the Vibepollo UUID (nil for non-Steam apps)
    let steamAppId: Int?

    var pinned: Bool { pinIndex != nil }

    /// On a PC (streamable), as opposed to a Steam game you own that isn't installed
    var isInstalled: Bool { !host.isEmpty }

    static func steamOnly(appid: Int, name: String) -> GameItem {
        GameItem(["host": "", "app": "steam-\(appid)", "name": name.isEmpty ? "Steam game \(appid)" : name,
                  "steamAppId": appid])!
    }

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
        artStamp = (dict["artStamp"] as? NSNumber)?.doubleValue ?? 0
        let steamId = (dict["steamAppId"] as? NSNumber)?.intValue ?? 0
        steamAppId = steamId > 0 ? steamId : nil
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

struct GameDetailRoute: Equatable {
    let game: GameItem
    let source: String
    let tab: StarlightTab
    var gameId: String { game.id }
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

    // Navigation state
    @Published var tab: StarlightTab = .home {
        didSet {
            guard tab != oldValue else { return }
            previousTab = oldValue
            detail = nil
            closePC()
            closeGameMenu()
            GameFocus.shared.focusedID = nil
            // Settings has its own focus scope: the Home/Library cards stay loaded in the
            // other tabs and would otherwise steal the controller selection
            if oldValue == .settings {
                for scope in GameFocus.shared.scopes.reversed() where scope.hasPrefix("settings") {
                    GameFocus.shared.pop(scope)
                }
                GameFocus.shared.focusedID = nil
            }
            GameFocus.shared.baseScope = tab.focusScope
            if tab == .search {
                searchFieldFocused = true
            } else if oldValue == .search {
                searchFieldFocused = false
            }
        }
    }
    var previousTab: StarlightTab = .home
    @Published var pcExpanded = false
    @Published var gameMenu: GameItem?
    /// The game page that's open (zoom transition from the card it was opened from)
    @Published var detail: GameDetailRoute?
    var lastControllerInput = Date.distantPast

    /// Continue Playing: a card is selected (featured) rather than opened; Play at the top starts it
    func feature(_ game: GameItem, row: String) {
        guard featuredId != game.id || featuredRow != row else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            featuredId = game.id
            featuredRow = row
        }
    }
    @Published var searchQuery = ""
    @Published var searchFieldFocused = false

    func select(_ newTab: StarlightTab) {
        closePC()
        closeGameMenu()
        if newTab != tab {
            tab = newTab
        }
    }

    func openDetail(_ game: GameItem, source: String) {
        guard #available(iOS 16.0, *) else {
            launch(game)
            return
        }
        closePC()
        closeGameMenu()
        detail = GameDetailRoute(game: game, source: source, tab: tab)
    }

    func closeDetail() {
        detail = nil
    }

    var detailGame: GameItem? {
        guard let route = detail else { return nil }
        return games.first { $0.id == route.gameId } ?? route.game
    }

    func togglePC() { pcExpanded ? closePC() : openPC() }

    func openPC() {
        closeGameMenu()
        pcExpanded = true
        GameFocus.shared.push("pc")
    }

    func closePC() {
        guard pcExpanded else { return }
        pcExpanded = false
        GameFocus.shared.pop("pc")
    }

    func openGameMenu(_ game: GameItem) {
        closePC()
        gameMenu = game
        GameFocus.shared.push("menu")
    }

    func closeGameMenu() {
        guard gameMenu != nil else { return }
        gameMenu = nil
        GameFocus.shared.pop("menu")
    }

    func openSearch(fromController: Bool) {
        closePC()
        closeGameMenu()
        if tab != .search {
            tab = .search
        }
        searchFieldFocused = true
    }

    func closeSearch() {
        searchFieldFocused = false
        searchQuery = ""
        select(previousTab == .search ? .home : previousTab)
    }

    func switchTab(by delta: Int) {
        let tabs = StarlightTab.barTabs
        let index = tabs.firstIndex(of: tab) ?? 0
        // From Search, L1/R1 continue from the tab you came from
        let base = tab == .search ? (tabs.firstIndex(of: previousTab) ?? 0) : index
        select(tabs[(base + delta + tabs.count) % tabs.count])
    }

    /// The game the controller is on: the focused cover in Library/Search, the featured game on Home
    var focusedOrFeaturedGame: GameItem? {
        if let game = detailGame { return game }
        if tab != .home, let id = GameFocus.shared.focusedID {
            for prefix in ["lib-", "search-"] where id.hasPrefix(prefix) {
                let gameId = String(id.dropFirst(prefix.count))
                if let game = games.first(where: { $0.id == gameId }) { return game }
            }
        }
        return tab == .home ? featured : nil
    }

    /// Controller input on the Starlight screens
    func handlePad(_ event: GamepadInput.Event) {
        lastControllerInput = Date()
        let focus = GameFocus.shared
        if editingGame != nil {
            if event == .back { editingGame = nil }
            return
        }
        switch event {
        case .up: focus.move(.up)
        case .down: focus.move(.down)
        case .left: focus.move(.left)
        case .right: focus.move(.right)
        case .confirm: focus.activate()
        case .back:
            // A Settings text field being edited: ○ closes the keyboard first
            if focus.textEditing {
                focus.textEditing = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                return
            }
            if searchFieldFocused {
                searchFieldFocused = false
            } else if gameMenu != nil {
                closeGameMenu()
            } else if pcExpanded {
                closePC()
            } else if detail != nil {
                closeDetail()
            } else if focus.handleBack() {
                break
            } else if tab == .search {
                closeSearch()
            }
        case .search: openSearch(fromController: true)
        case .pc: togglePC()
        case .options:
            if gameMenu != nil {
                closeGameMenu()
            } else if let game = focusedOrFeaturedGame, game.isInstalled {
                openGameMenu(game)
            }
        case .play:
            if gameMenu == nil, !pcExpanded, let game = focusedOrFeaturedGame, game.isInstalled { launch(game) }
        case .previousTab: switchTab(by: -1)
        case .nextTab: switchTab(by: 1)
        }
    }


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

    /// How far back Continue Playing looks
    static let continueWindow: TimeInterval = 30 * 24 * 3600

    /// Only games started recently (through Starlight or on the PC per Steam) or running now, newest first
    var continueGames: [GameItem] {
        let cutoff = Date().addingTimeInterval(-Self.continueWindow)
        return games
            .filter { !$0.hidden && ($0.running || (effectiveLastPlayed($0).map { $0 >= cutoff } ?? false)) }
            .sorted { a, b in
                if a.running != b.running { return a.running }
                return (effectiveLastPlayed(a) ?? .distantPast) > (effectiveLastPlayed(b) ?? .distantPast)
            }
    }

    /// Games hidden on the current PC (managed in Settings → Hidden Games)
    var hiddenGames: [GameItem] {
        games.filter(\.hidden).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Most recent of: played through Starlight, or played on the PC according to Steam
    func effectiveLastPlayed(_ game: GameItem) -> Date? {
        let steamDate = game.steamAppId.flatMap { SteamManager.shared.owned($0)?.lastPlayed }
        switch (game.lastPlayed, steamDate) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    /// Pinned games first, then alphabetical; hidden games live in Settings → Hidden Games
    var libraryGames: [GameItem] {
        games.filter { !$0.hidden }.sorted { a, b in
            if let pinned = pinnedFirst(a, b) { return pinned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The game the user tapped, else the running game, else the first of Continue Playing
    var featured: GameItem? {
        if let id = featuredId, let game = games.first(where: { $0.id == id }) { return game }
        return games.first(where: { $0.running }) ?? continueGames.first ?? libraryGames.first
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

    func remove(_ paths: [String?]) {
        for case let path? in paths { cache.removeObject(forKey: path as NSString) }
    }
}

let starlightGold = Color(red: 0.86, green: 0.72, blue: 0.42)

// MARK: - Glass helpers (Liquid Glass on iOS 26, materials before)

extension View {
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
