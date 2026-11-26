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
//    StarlightOnboarding     setup guide on first launch (and from Settings › About)
//

import SwiftUI
import CoreSpotlight
import UniformTypeIdentifiers
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
        // A game tapped in Spotlight (AppDelegate stores it and posts this)
        NotificationCenter.default.addObserver(forName: Notification.Name("StarlightOpenGame"), object: nil, queue: .main) { [weak homeModel] _ in
            homeModel?.openPendingSpotlightGame()
        }
        // Steam data: refresh when it's more than a few hours old
        Task { @MainActor in SteamManager.shared.refreshIfStale() }
        // Handoff: open the tab, PC and game page the other device was on
        StarlightHandoff.shared.onBrowse = { [weak homeModel] info in
            homeModel?.continueBrowsing(info)
        }
        homeModel.advertiseHandoff()
    }

    /// On while the Starlight screens are visible, off during a stream
    @objc func setControllerInputActive(_ active: Bool) {
        GamepadInput.shared.active = active
        // Same moments: the carousel trailer pauses while a stream (or anything else) covers the Home screen
        HomeTrailerState.shared.screenActive = active
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

    /// The setup guide is showing: pairing PINs go to it instead of an alert
    @objc var onboardingVisible: Bool { model.onboardingVisible }

    /// Pairing started from the setup guide: the PIN to enter on the PC
    @objc func showPairingPIN(_ pin: String) {
        model.pairingError = nil
        model.pairingPIN = pin
    }

    /// Pairing from the setup guide ended: nil on success, else the reason it failed
    @objc func pairingFinished(_ error: String?) {
        model.pairingPIN = nil
        model.pairingError = error
    }

    @objc(updateWithHosts:selectedHost:apps:artwork:)
    func update(hosts: [[String: Any]], selectedHost: String?, apps: [[String: Any]], artwork: [String: Any]) {
        let hostItems = hosts.compactMap(HostItem.init)
        let gameItems = apps.compactMap(GameItem.init)
        if model.hosts != hostItems { model.hosts = hostItems }
        model.decideOnboarding()
        if model.selectedHost != selectedHost { model.selectedHost = selectedHost }
        if model.games != gameItems {
            // Only drop the images of games whose artwork changed (artStamp follows the files' dates)
            let oldStamps = Dictionary(model.games.map { ($0.id, $0.artStamp) }, uniquingKeysWith: { first, _ in first })
            for game in gameItems where oldStamps[game.id].map({ $0 != game.artStamp }) ?? false {
                ArtworkCache.shared.remove([game.gridPath, game.heroPath, game.logoPath])
            }
            model.games = gameItems
            GameFirstSeen.record(gameItems)
        }
        let configured = artwork["configured"] as? Bool ?? false
        let suffix = artwork["keySuffix"] as? String ?? ""
        if model.artworkConfigured != configured { model.artworkConfigured = configured }
        if model.artworkKeySuffix != suffix { model.artworkKeySuffix = suffix }
        let artworkBusy = artwork["busy"] as? Bool ?? false
        let artworkFailed = artwork["failed"] as? Bool ?? false
        if model.artworkBusy != artworkBusy { model.artworkBusy = artworkBusy }
        if model.artworkFailed != artworkFailed { model.artworkFailed = artworkFailed }
        // Spotlight: Ready to Play games, and a result tapped there before the games had loaded
        StarlightSpotlight.index(model.libraryGames)
        model.openPendingSpotlightGame()
        model.openPendingHandoffGame()
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
    /// Settings → Refresh Games in progress, and whether the last one failed
    let refreshing: Bool
    let refreshFailed: Bool
    /// Connecting: finding out whether the PC is there, waking it, or talking to it (background work)
    let busy: Bool

    init?(_ dict: [String: Any]) {
        guard let uuid = dict["uuid"] as? String else { return nil }
        id = uuid
        name = dict["name"] as? String ?? "PC"
        online = dict["online"] as? Bool ?? false
        paired = dict["paired"] as? Bool ?? false
        showHidden = dict["showHidden"] as? Bool ?? false
        permissionDenied = dict["permissionDenied"] as? Bool ?? false
        address = dict["address"] as? String ?? ""
        refreshing = dict["refreshing"] as? Bool ?? false
        refreshFailed = dict["refreshFailed"] as? Bool ?? false
        busy = dict["busy"] as? Bool ?? false
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
    /// The app's UUID on the PC (Vibepollo), when it sends one
    let uuid: String?
    /// Rubylight: the device the running game is on ("this device", "iPhone do João"…), nil elsewhere
    let runningOn: String?
    /// Rubylight: the main button for the running game, "resume", "continue" (Continue here) or "join"
    let playAction: String?

    /// The main button's title
    var playTitle: String {
        switch playAction {
        case "join": return "Join"
        case "continue": return "Continue Here"
        default: return running ? "Resume" : "Play"
        }
    }

    /// The green badge: on Rubylight the device it runs on, elsewhere the PC
    var runningBadge: String { "Running on " + (runningOn ?? "PC") }

    /// Rubylight, another device streams it: Join is the main button, Continue here goes in •••
    var canContinueHere: Bool { playAction == "join" }

    /// Identifies the game on its PC across app-list refreshes: the UUID, else the app id
    var stableKey: String { uuid ?? app }

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
        uuid = GameItem.nonEmpty(dict["uuid"])
        runningOn = GameItem.nonEmpty(dict["runningOn"])
        playAction = GameItem.nonEmpty(dict["playAction"])
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

/// When Starlight first saw each game on each PC (by PC and app UUID): Vibepollo doesn't say when an app was added.
/// The first time a PC's list is seen (including the first run of this version) its games count as already known,
/// so New on Your PC doesn't start out full.
enum GameFirstSeen {
    private static let key = "StarlightFirstSeen"
    private static var cache: [String: [String: Double]]?

    private static func load() -> [String: [String: Double]] {
        if let cache = cache { return cache }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        cache = stored
        return stored
    }

    static func record(_ games: [GameItem]) {
        let installed = games.filter(\.isInstalled)
        guard !installed.isEmpty else { return }
        var all = load()
        var changed = false
        let now = Date().timeIntervalSince1970
        for (host, list) in Dictionary(grouping: installed, by: \.host) {
            if var seen = all[host] {
                for game in list where seen[game.stableKey] == nil {
                    seen[game.stableKey] = now
                    changed = true
                }
                all[host] = seen
            } else {
                // 0: known from before, never "new"
                all[host] = Dictionary(list.map { ($0.stableKey, 0.0) }, uniquingKeysWith: { first, _ in first })
                changed = true
            }
        }
        if changed {
            cache = all
            UserDefaults.standard.set(all, forKey: key)
        }
    }

    static func date(_ game: GameItem) -> Date? {
        guard let seconds = load()[game.host]?[game.stableKey], seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
    @Published var selectedHost: String? {
        didSet { if selectedHost != oldValue { advertiseHandoff() } }
    }
    @Published var games: [GameItem] = []
    @Published var featuredId: String?
    /// Which row the featured game was picked from, so only that card is outlined
    @Published var featuredRow = "continue"
    @Published var editingGame: GameItem?
    @Published var artworkConfigured = false
    @Published var artworkKeySuffix = ""
    /// SteamGridDB / Steam artwork download running (Settings → Game Artwork), and its last result
    @Published var artworkBusy = false
    @Published var artworkFailed = false

    // MARK: Setup guide (first launch)

    @Published var onboardingVisible = false
    /// PIN shown while pairing from the guide, and the last pairing error
    @Published var pairingPIN: String?
    @Published var pairingError: String?
    private var onboardingDecided = false
    static let onboardingDoneKey = "StarlightOnboardingDone"

    /// On the first state from the app: show the guide on a first launch. People who already
    /// paired a PC (earlier builds) never see it unless they open it from Settings.
    func decideOnboarding() {
        guard !onboardingDecided else { return }
        onboardingDecided = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.onboardingDoneKey) { return }
        if hosts.contains(where: \.paired) {
            defaults.set(true, forKey: Self.onboardingDoneKey)
            return
        }
        onboardingVisible = true
    }

    func showOnboarding() {
        pairingPIN = nil
        pairingError = nil
        withAnimation(.easeInOut(duration: 0.3)) { onboardingVisible = true }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
        withAnimation(.easeInOut(duration: 0.35)) { onboardingVisible = false }
    }

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
            TabBarAutoHide.shared.reset()
            detail = nil
            closePC()
            advertiseHandoff()
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
    @Published var detail: GameDetailRoute? {
        didSet { if detail?.gameId != oldValue?.gameId { advertiseHandoff() } }
    }
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
        // A result picked from a search: remember the search
        if tab == .search { RecentSearches.add(searchQuery) }
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

    /// Opens the game page of a Spotlight result once its game is in the list
    func openPendingSpotlightGame() {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: StarlightSpotlight.pendingKey) else { return }
        if let game = games.first(where: { $0.id == id && !$0.hidden }) {
            defaults.removeObject(forKey: StarlightSpotlight.pendingKey)
            if tab == .settings || tab == .search { tab = .home }
            openDetail(game, source: "spotlight-\(game.id)")
        } else if let host = id.split(separator: "|").first, games.contains(where: { $0.host == host }) {
            // That PC's list is loaded and the game isn't in it any more
            defaults.removeObject(forKey: StarlightSpotlight.pendingKey)
        }
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
            } else if focus.handleBack() {
                // A page or viewer opened from the game page (or a Settings screen) goes back first
                break
            } else if detail != nil {
                closeDetail()
            } else if tab == .search {
                closeSearch()
            }
        case .search: openSearch(fromController: true)
        case .pc: togglePC()
        case .options:
            if gameMenu != nil {
                closeGameMenu()
            } else if let game = focusedOrFeaturedGame {
                openGameMenu(game)
            }
        case .play:
            if gameMenu == nil, !pcExpanded, let game = focusedOrFeaturedGame, game.isInstalled { launch(game) }
        case .previousTab: switchTab(by: -1)
        case .nextTab: switchTab(by: 1)
        }
    }


    var currentHost: HostItem? { hosts.first { $0.id == selectedHost } }

    // MARK: Handoff

    /// Where you are, for your other devices: the tab, the PC and the game page that's open (no keys or private data)
    func advertiseHandoff() {
        var info: [String: Any] = ["tab": tab.rawValue]
        if let host = selectedHost { info["host"] = host }
        var title = "Starlight \(tab.title)"
        if let game = detailGame, game.isInstalled {
            var gameInfo: [String: Any] = ["app": game.app]
            if let uuid = game.uuid { gameInfo["uuid"] = uuid }
            if let appid = game.steamAppId { gameInfo["steamAppId"] = appid }
            info["host"] = game.host
            info["game"] = gameInfo
            title = game.name
        }
        StarlightHandoff.shared.advertiseBrowse(info, title: title)
    }

    /// A game page to open once its PC's games are listed (from Handoff)
    private var pendingHandoffGame: (host: String, app: String, uuid: String?, steamAppId: Int?)?

    /// Browsing continued from another device: same tab, same PC (if it's paired here), same game page
    func continueBrowsing(_ info: [String: Any]) {
        if let raw = info["tab"] as? String, let tab = StarlightTab(rawValue: raw) {
            self.tab = tab
        }
        guard let host = info["host"] as? String, hosts.contains(where: { $0.id == host && $0.paired }) else { return }
        if selectedHost != host {
            onSelectHost?(host)
        }
        if let game = info["game"] as? [String: Any], let app = game["app"] as? String {
            pendingHandoffGame = (host, app, game["uuid"] as? String, (game["steamAppId"] as? NSNumber)?.intValue)
            openPendingHandoffGame()
        }
    }

    func openPendingHandoffGame() {
        guard let pending = pendingHandoffGame else { return }
        let onHost = games.filter { $0.host == pending.host && !$0.hidden }
        guard !onHost.isEmpty else { return }   // that PC's games aren't listed yet
        pendingHandoffGame = nil
        let match = onHost.first { pending.uuid != nil && $0.uuid == pending.uuid }
            ?? onHost.first { $0.app == pending.app }
            ?? onHost.first { pending.steamAppId != nil && $0.steamAppId == pending.steamAppId }
        guard let game = match else { return }
        if tab == .settings || tab == .search { tab = .home }
        openDetail(game, source: "handoff-\(game.id)")
    }
    var pairedHosts: [HostItem] { hosts.filter { $0.paired } }
    var networkHosts: [HostItem] { hosts.filter { !$0.paired } }

    /// How far back Continue Playing looks
    static let continueWindow: TimeInterval = 30 * 24 * 3600

    /// New on Your PC: games that turned up in the PC's list in the last 14 days, newest first
    static let newOnPCWindow: TimeInterval = 14 * 24 * 60 * 60

    var newOnPCGames: [GameItem] {
        let cutoff = Date().addingTimeInterval(-Self.newOnPCWindow)
        return games
            .compactMap { game -> (GameItem, Date)? in
                guard !game.hidden, game.isInstalled, let seen = GameFirstSeen.date(game), seen >= cutoff else { return nil }
                return (game, seen)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Playing Now: games running on the PC, started from this device or another one
    var playingGames: [GameItem] {
        games.filter { !$0.hidden && $0.running }
    }

    /// Pinned: the pinned games, in their pinned order
    var pinnedGames: [GameItem] {
        games
            .filter { !$0.hidden && $0.pinned }
            .sorted { ($0.pinIndex ?? 0) < ($1.pinIndex ?? 0) }
    }

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
    /// Ready to Play: by name (pinned games have their own row on Home, so they're not put first)
    var libraryGames: [GameItem] {
        games.filter { !$0.hidden }.sorted { a, b in
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
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

/// Artwork of Steam games that aren't on the PC. It's downloaded on demand, as the games appear
/// on screen, into the same cache as PC games and with the same order (Edit Artwork choice,
/// Steam, SteamGridDB). Views observe `revision` to pick up new files.
final class SteamOnlyArtwork: ObservableObject {
    static let shared = SteamOnlyArtwork()
    @Published private(set) var revision = 0
    private var requested: Set<String> = []
    private var pendingBump = false

    private init() {
        // SteamGridDBArtworkUpdatedNotification (object: the game's name)
        NotificationCenter.default.addObserver(forName: Notification.Name("StarlightArtworkUpdated"), object: nil, queue: .main) { [weak self] note in
            if let name = note.object as? String {
                // The file may have been replaced in place (Edit Artwork)
                ArtworkCache.shared.remove(["grid", "hero", "logo"].map { SteamGridDBManager.shared().cachedPath(appName: name, kind: $0) })
            }
            self?.scheduleBump()
        }
    }

    /// Coalesces bursts of downloads into one refresh
    private func scheduleBump() {
        guard !pendingBump else { return }
        pendingBump = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pendingBump = false
            self?.revision += 1
        }
    }

    func ensure(_ game: GameItem) {
        guard !game.isInstalled, let appid = game.steamAppId, requested.insert(game.name).inserted else { return }
        SteamGridDBManager.shared().ensureArtwork(appName: game.name, steamAppId: UInt64(appid))
    }

    /// After the artwork cache is cleared
    func reset() { requested.removeAll() }
}

extension GameItem {
    /// Cover ("grid"), background ("hero") or logo file. Games on the PC carry their paths;
    /// Steam-only games read the on-demand cache.
    func artPath(_ kind: String) -> String? {
        if isInstalled {
            switch kind {
            case "grid": return gridPath
            case "hero": return heroPath
            case "logo": return logoPath
            default: return nil
            }
        }
        return SteamGridDBManager.shared().cachedPath(appName: name, kind: kind)
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


// MARK: - Spotlight

/// Ready to Play games in the iPhone's search, with their cover. Tapping one opens its game page.
enum StarlightSpotlight {
    static let domain = "games"
    static let pendingKey = "StarlightPendingOpenGame"
    private static var signature = ""
    private static let queue = DispatchQueue(label: "starlight.spotlight", qos: .utility)

    static func index(_ games: [GameItem]) {
        let ready = games.filter { $0.isInstalled && !$0.hidden }
        let newSignature = ready.map { "\($0.id)|\($0.name)|\($0.artStamp)" }.joined(separator: "\n")
        guard newSignature != signature else { return }
        signature = newSignature
        queue.async {
            let items = ready.map { game -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
                attributes.title = game.name
                attributes.contentDescription = game.hostName.isEmpty ? "Ready to Play" : "Ready to Play on \(game.hostName)"
                attributes.keywords = ["game", "play", "Starlight"] + (game.steamAppId != nil ? ["Steam"] : [])
                if let path = game.gridPath, let image = UIImage(contentsOfFile: path) {
                    attributes.thumbnailData = thumbnail(image)
                }
                return CSSearchableItem(uniqueIdentifier: "game|" + game.id, domainIdentifier: domain, attributeSet: attributes)
            }
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                if !items.isEmpty { index.indexSearchableItems(items, completionHandler: nil) }
            }
        }
    }

    /// Small JPEG of the cover (Spotlight shows it at icon size)
    private static func thumbnail(_ image: UIImage) -> Data? {
        let width: CGFloat = 180
        let scale = width / max(image.size.width, 1)
        let size = CGSize(width: width, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.8)
    }
}
