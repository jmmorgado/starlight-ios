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
    let widePath: String?
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
        widePath = GameItem.nonEmpty(dict["widePath"])
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
    @Published var tabBarFocused = false
    @Published var tabBarFlash = false
    @Published var tabBarCollapsedByScroll = false
    @Published var searchQuery = ""
    @Published var searchFieldFocused = false
    private var lastScrollOffset: CGFloat = 0
    private var flashWork: DispatchWorkItem?

    func select(_ newTab: StarlightTab) {
        closePC()
        closeGameMenu()
        unfocusTabBar()
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
        unfocusTabBar()
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
        unfocusTabBar()
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

    func expandTabBar() {
        if DeviceStatus.shared.controllerConnected {
            focusTabBar()
        } else {
            tabBarCollapsedByScroll = false
        }
    }

    func focusTabBar() {
        guard !tabBarFocused else { return }
        closePC()
        closeGameMenu()
        tabBarFocused = true
        GameFocus.shared.push("tabbar")
        let current = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if StarlightTab.barTabs.contains(current) { GameFocus.shared.focus("tab-\(current.rawValue)") }
        }
    }

    func unfocusTabBar() {
        guard tabBarFocused else { return }
        tabBarFocused = false
        GameFocus.shared.pop("tabbar")
    }

    func switchTab(by delta: Int) {
        let tabs = StarlightTab.barTabs
        let index = tabs.firstIndex(of: tab) ?? 0
        // From Search, L1/R1 continue from the tab you came from
        let base = tab == .search ? (tabs.firstIndex(of: previousTab) ?? 0) : index
        select(tabs[(base + delta + tabs.count) % tabs.count])
        flashWork?.cancel()
        tabBarFlash = true
        let work = DispatchWorkItem { [weak self] in self?.tabBarFlash = false }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func scrolled(to offset: CGFloat) {
        var collapsed = tabBarCollapsedByScroll
        if offset < lastScrollOffset - 6 && offset < -20 {
            collapsed = true
        } else if offset > lastScrollOffset + 6 || offset > -20 {
            collapsed = false
        }
        lastScrollOffset = offset
        if collapsed != tabBarCollapsedByScroll { tabBarCollapsedByScroll = collapsed }
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
            } else if tabBarFocused {
                unfocusTabBar()
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

enum StarlightTab: String, CaseIterable {
    case home, library, settings, search

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }

    /// Controller focus space for the tab
    var focusScope: String {
        switch self {
        case .home: return "main"
        case .library: return "library"
        case .settings: return "settings"
        case .search: return "search"
        }
    }

    /// The tabs shown in the tab bar (Search has its own button at the top)
    static let barTabs: [StarlightTab] = [.home, .library, .settings]
}

struct HomeRootView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            tabs

            if model.pcExpanded {
                PCDropdown(model: model)
            }

            if let game = model.gameMenu {
                GameActionPanel(model: model, game: game)
            }
        }
        .onPreferenceChange(FocusFrameKey.self) { entries in
            GameFocus.shared.entries = entries
        }
        .tint(starlightGold)
        .preferredColorScheme(.dark)
        .sheet(item: $model.editingGame) { game in
            ArtworkEditorView(model: model, game: game)
                .preferredColorScheme(.dark)
        }
    }

    /// System tab bar (Liquid Glass on iOS 26). The Search tab is the round button at the bottom right
    /// that expands into the search field. L1 / R1 change the selection.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $model.tab) {
                Tab(StarlightTab.home.title, systemImage: StarlightTab.home.symbol, value: StarlightTab.home) {
                    StarlightStack { HomeTab(model: model).starlightToolbar(model) }
                }
                Tab(StarlightTab.library.title, systemImage: StarlightTab.library.symbol, value: StarlightTab.library) {
                    StarlightStack {
                        LibraryTab(model: model)
                            .navigationTitle("Library")
                            .starlightToolbar(model)
                    }
                    .environment(\.focusTabScope, "library")
                }
                Tab(StarlightTab.settings.title, systemImage: StarlightTab.settings.symbol, value: StarlightTab.settings) {
                    SettingsTab(model: model)
                }
                Tab(value: StarlightTab.search, role: .search) {
                    StarlightStack { NativeSearchScreen(model: model) }
                        .environment(\.focusTabScope, "search")
                }
            }
            .modifier(TabBarMinimizeOnScroll())
        } else {
            TabView(selection: $model.tab) {
                StarlightStack { HomeTab(model: model).starlightToolbar(model) }
                    .tabItem { Label(StarlightTab.home.title, systemImage: StarlightTab.home.symbol) }
                    .tag(StarlightTab.home)
                StarlightStack {
                    LibraryTab(model: model)
                        .navigationTitle("Library")
                        .starlightToolbar(model)
                }
                .environment(\.focusTabScope, "library")
                .tabItem { Label(StarlightTab.library.title, systemImage: StarlightTab.library.symbol) }
                .tag(StarlightTab.library)
                SettingsTab(model: model)
                    .tabItem { Label(StarlightTab.settings.title, systemImage: StarlightTab.settings.symbol) }
                    .tag(StarlightTab.settings)
                StarlightStack { NativeSearchScreen(model: model) }
                    .environment(\.focusTabScope, "search")
                    .tabItem { Label(StarlightTab.search.title, systemImage: StarlightTab.search.symbol) }
                    .tag(StarlightTab.search)
            }
        }
    }
}

/// iOS 26: the tab bar shrinks to the selected tab's icon while scrolling down, like Photos
struct TabBarMinimizeOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

/// NavigationStack where available (needed for the iOS 26 toolbar and search behaviour)
struct StarlightStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// PC button on the leading side and the status on the trailing side of the system navigation bar.
    /// On iOS 26 the system draws both as Liquid Glass and the PC menu opens with the native morph.
    func starlightToolbar(_ model: HomeModel) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same side, same group: iOS 26 draws the PC button and the status in one Liquid Glass capsule
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    PCToolbarButton(model: model)
                    StatusCluster()
                }
            }
    }

    func starlightStatusToolbar() -> some View {
        self.toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                StatusCluster()
            }
        }
    }
}

/// Search with the system search field (focus follows △ on the controller)
struct NativeSearchScreen: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        if #available(iOS 18.0, *) {
            FocusedSearch(model: model)
        } else {
            SearchTab(model: model)
                .navigationTitle("Search")
                .starlightToolbar(model)
                .searchable(text: $model.searchQuery, prompt: "Search game")
        }
    }
}

@available(iOS 18.0, *)
private struct FocusedSearch: View {
    @ObservedObject var model: HomeModel
    @FocusState private var focused: Bool

    var body: some View {
        SearchTab(model: model)
            .navigationTitle("Search")
            .starlightToolbar(model)
            .searchable(text: $model.searchQuery, prompt: "Search game")
            .searchFocused($focused)
            .onAppear { focused = model.searchFieldFocused }
            .onChange(of: model.searchFieldFocused) { _, value in
                if focused != value { focused = value }
            }
            .onChange(of: focused) { _, value in
                if model.searchFieldFocused != value { model.searchFieldFocused = value }
            }
    }
}

/// The PC button in the navigation bar: a native menu (opens with the system animation).
/// With a controller connected it shows □, and □ opens the navigable PC panel (system menus can't be driven by a controller).
struct PCToolbarButton: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared

    var body: some View {
        // Always the system menu on touch; □ on the controller opens the navigable PC panel
        Group {
            Menu {
                if !model.pairedHosts.isEmpty {
                    Section(model.currentHost.map { "Connected to \($0.name)" } ?? "Your PCs") {
                        ForEach(model.pairedHosts) { host in
                            Button { model.onSelectHost?(host.id) } label: {
                                Label(host.name + (host.online ? "" : " · offline"),
                                      systemImage: host.id == model.selectedHost ? "checkmark" : "desktopcomputer")
                            }
                        }
                    }
                }
                if !model.networkHosts.isEmpty {
                    Section("On Your Network") {
                        ForEach(model.networkHosts) { host in
                            Button { model.onSelectHost?(host.id) } label: {
                                Label("\(host.name) · pair", systemImage: "link")
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
                label
            }
            .accessibilityLabel(accessibility)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                    .offset(x: 3, y: 2)
            }
            if device.controllerConnected {
                Image(systemName: PadGlyph.pc)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        guard let host = model.currentHost else { return .gray }
        if !host.paired { return .orange }
        return host.online ? .green : .gray
    }

    private var accessibility: String {
        guard let host = model.currentHost else { return "Choose a PC" }
        return "PC \(host.name), " + (!host.paired ? "not paired" : (host.online ? "online" : "offline"))
    }
}

// MARK: - Controller glyphs

/// The connected controller's own button symbols (✕ ○ △ □ on PlayStation, A B Y X on Xbox)
enum PadGlyph {
    static var pad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad
    }

    static var search: String { pad?.buttonY.sfSymbolsName ?? "triangle.circle" }
    static var pc: String { pad?.buttonX.sfSymbolsName ?? "square.circle" }
    static var confirm: String { pad?.buttonA.sfSymbolsName ?? "a.circle" }
    static var play: String { pad?.rightTrigger.sfSymbolsName ?? "r2.rectangle.roundedtop" }
    static var options: String { pad?.buttonMenu.sfSymbolsName ?? "line.3.horizontal.circle" }
    static var leftShoulder: String { pad?.leftShoulder.sfSymbolsName ?? "l1.rectangle.roundedbottom" }
    static var rightShoulder: String { pad?.rightShoulder.sfSymbolsName ?? "r1.rectangle.roundedbottom" }
}

// MARK: - Focus engine (controller navigation)

struct FocusEntry: Equatable {
    let id: String
    let scope: String
    let rect: CGRect
}

struct FocusFrameKey: PreferenceKey {
    static var defaultValue: [FocusEntry] = []
    static func reduce(value: inout [FocusEntry], nextValue: () -> [FocusEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// Spatial focus for game controllers: elements report their frames, the D-pad moves to the
/// nearest element in that direction within the active scope (main screen, PC menu, game menu, tab bar).
final class GameFocus: ObservableObject {
    static let shared = GameFocus()

    enum Direction { case up, down, left, right }

    @Published var focusedID: String?
    @Published private(set) var scopes: [String] = []
    var entries: [FocusEntry] = []
    private var actions: [String: () -> Void] = [:]
    private var saved: [String: String] = [:]

    /// The focus space of the tab on screen ("main" = Home); each tab keeps its own,
    /// because the other tabs stay loaded and their cards would steal the selection
    var baseScope = "main"
    var activeScope: String { scopes.last ?? baseScope }

    private var grids: [String: (ids: [String], columns: Int)] = [:]
    private var adjusters: [String: (Int) -> Void] = [:]
    /// A Settings text field has the keyboard up
    var textEditing = false
    private var backHandlers: [String: () -> Void] = [:]

    func registerAdjust(_ id: String, _ adjust: ((Int) -> Void)?) -> Bool {
        adjusters[id] = adjust
        return true
    }

    func setBack(_ scope: String, _ handler: (() -> Void)?) {
        backHandlers[scope] = handler
    }

    /// ○ on a pushed Settings screen goes back
    func handleBack() -> Bool {
        guard let handler = backHandlers[activeScope] else { return false }
        handler()
        return true
    }

    func registerGrid(_ name: String, ids: [String], columns: Int) -> Bool {
        grids[name] = (ids, columns)
        return true
    }

    func register(_ id: String, _ action: @escaping () -> Void) -> Bool {
        actions[id] = action
        return true
    }

    func push(_ scope: String) {
        guard scopes.last != scope else { return }
        saved[activeScope] = focusedID
        scopes.append(scope)
        focusedID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if self?.focusedID == nil { self?.focusFirst() }
        }
    }

    func pop(_ scope: String) {
        guard let index = scopes.lastIndex(of: scope) else { return }
        scopes.remove(at: index)
        focusedID = saved[activeScope]
    }

    func focus(_ id: String) { focusedID = id }

    private var candidates: [FocusEntry] {
        entries.filter { $0.scope == activeScope && $0.rect.width > 0 }
    }

    func focusFirst() {
        let sorted = candidates.sorted {
            abs($0.rect.minY - $1.rect.minY) > 8 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        focusedID = sorted.first?.id
    }

    func move(_ direction: Direction) {
        // ← / → change the value of the focused setting instead of moving
        if (direction == .left || direction == .right), let id = focusedID,
           candidates.contains(where: { $0.id == id }), let adjust = adjusters[id] {
            adjust(direction == .left ? -1 : 1)
            return
        }
        if let id = focusedID, ["main", "library", "search"].contains(activeScope),
           let grid = grids.values.first(where: { $0.ids.contains(id) }), let index = grid.ids.firstIndex(of: id) {
            var target = index
            switch direction {
            case .left: target = index % grid.columns == 0 ? -1 : index - 1
            case .right: target = (index + 1) % grid.columns == 0 ? -1 : index + 1
            case .up: target = index - grid.columns
            case .down: target = index + grid.columns
            }
            if direction == .down && target >= grid.ids.count && index / grid.columns < (grid.ids.count - 1) / grid.columns {
                target = grid.ids.count - 1
            }
            if grid.ids.indices.contains(target) {
                focusedID = grid.ids[target]
            }
            return
        }
        let list = candidates
        guard !list.isEmpty else { return }
        guard let current = list.first(where: { $0.id == focusedID }) else {
            focusFirst()
            return
        }
        let from = CGPoint(x: current.rect.midX, y: current.rect.midY)
        var best: (FocusEntry, CGFloat)?
        for entry in list where entry.id != current.id {
            let to = CGPoint(x: entry.rect.midX, y: entry.rect.midY)
            let dx = to.x - from.x
            let dy = to.y - from.y
            let primary: CGFloat
            let secondary: CGFloat
            switch direction {
            case .right: primary = dx; secondary = abs(dy)
            case .left: primary = -dx; secondary = abs(dy)
            case .down: primary = dy; secondary = abs(dx)
            case .up: primary = -dy; secondary = abs(dx)
            }
            guard primary > 4 else { continue }
            // Stay in the same row/column when possible
            let score = primary + secondary * (direction == .left || direction == .right ? 4 : 1.2)
            if best == nil || score < best!.1 {
                best = (entry, score)
            }
        }
        if let target = best?.0 {
            focusedID = target.id
        }
    }

    func activate() {
        guard let id = focusedID, candidates.contains(where: { $0.id == id }) else {
            focusFirst()
            return
        }
        actions[id]?()
    }
}

struct GameFocusModifier: ViewModifier {
    let id: String
    let scope: String
    let corner: CGFloat
    let action: () -> Void
    var scales = true
    var adjust: ((Int) -> Void)? = nil
    @ObservedObject private var focus = GameFocus.shared
    @ObservedObject private var device = DeviceStatus.shared
    @Environment(\.focusTabScope) private var tabScope

    func body(content: Content) -> some View {
        let _ = focus.register(id, action)
        let _ = focus.registerAdjust(id, adjust)
        // "main" means "the tab I'm in"
        let scope = self.scope == "main" ? tabScope : self.scope
        let focused = device.controllerConnected && focus.activeScope == scope && focus.focusedID == id
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: FocusFrameKey.self,
                                           value: [FocusEntry(id: id, scope: scope, rect: geo.frame(in: .global))])
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                    .stroke(starlightGold, lineWidth: focused ? 3 : 0)
                    .padding(-4)
            )
            .scaleEffect(focused && scales ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .id(id)
    }
}

extension View {
    /// A Settings row reachable with the controller: ✕ runs `action`, ← / → call `adjust` (pickers, sliders, switches)
    func settingsFocus(_ id: String, scope: String, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(GameFocusModifier(id: id, scope: scope, corner: 10, action: action, scales: false, adjust: adjust))
    }

    /// A pushed Settings screen: its own focus scope, and ○ goes back
    func settingsScreen(_ scope: String, dismiss: DismissAction) -> some View {
        self
            .onAppear {
                GameFocus.shared.push(scope)
                GameFocus.shared.setBack(scope) { dismiss() }
            }
            .onDisappear {
                GameFocus.shared.setBack(scope, nil)
                GameFocus.shared.pop(scope)
            }
    }
}

/// Scrolls a List/Form to the row the controller is on
struct FocusScrollFollower: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var focus = GameFocus.shared

    func body(content: Content) -> some View {
        content.onChange(of: focus.focusedID) { id in
            guard let id = id else { return }
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

private struct FocusTabScopeKey: EnvironmentKey {
    static let defaultValue = "main"
}

extension EnvironmentValues {
    /// The controller focus space of the tab a view lives in
    var focusTabScope: String {
        get { self[FocusTabScopeKey.self] }
        set { self[FocusTabScopeKey.self] = newValue }
    }
}

extension View {
    /// Makes the view reachable with the controller's D-pad; ✕ runs `action`
    func gameFocus(_ id: String, scope: String = "main", corner: CGFloat = 16, action: @escaping () -> Void) -> some View {
        modifier(GameFocusModifier(id: id, scope: scope, corner: corner, action: action))
    }
}

/// Reads the controller while the Starlight screens are on top (not during a stream, where
/// Moonlight's ControllerSupport takes over). Polling keeps it independent from those handlers.
final class GamepadInput {
    static let shared = GamepadInput()

    enum Event { case up, down, left, right, confirm, back, search, pc, options, previousTab, nextTab, play }

    var handler: ((Event) -> Void)?
    private var timer: Timer?
    private var previous: Set<String> = []
    private var heldDirection: String?
    private var nextRepeat = Date.distantFuture

    var active = false {
        didSet {
            guard active != oldValue else { return }
            timer?.invalidate()
            timer = nil
            previous = []
            heldDirection = nil
            if active {
                disableSystemGestures()
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
            }
        }
    }

    private func disableSystemGestures() {
        for controller in GCController.controllers() {
            for element in controller.physicalInputProfile.allElements {
                element.preferredSystemGestureState = .disabled
            }
        }
    }

    private func poll() {
        guard let pad = PadGlyph.pad else {
            previous = []
            return
        }
        var down: Set<String> = []
        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.6 { down.insert("up") }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.6 { down.insert("down") }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.6 { down.insert("left") }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.6 { down.insert("right") }
        if pad.buttonA.isPressed { down.insert("a") }
        if pad.buttonB.isPressed { down.insert("b") }
        if pad.buttonX.isPressed { down.insert("x") }
        if pad.buttonY.isPressed { down.insert("y") }
        if pad.buttonMenu.isPressed { down.insert("menu") }
        if pad.leftShoulder.isPressed { down.insert("l1") }
        if pad.rightShoulder.isPressed { down.insert("r1") }
        if pad.rightTrigger.isPressed { down.insert("r2") }

        let pressed = down.subtracting(previous)
        previous = down

        let map: [(String, Event)] = [
            ("up", .up), ("down", .down), ("left", .left), ("right", .right),
            ("a", .confirm), ("b", .back), ("y", .search), ("x", .pc),
            ("menu", .options), ("l1", .previousTab), ("r1", .nextTab), ("r2", .play)
        ]
        for (key, event) in map where pressed.contains(key) {
            handler?(event)
        }

        // Holding a direction repeats it
        let directions = ["up", "down", "left", "right"]
        if let held = directions.first(where: { down.contains($0) }) {
            if pressed.contains(held) || held != heldDirection {
                heldDirection = held
                nextRepeat = Date().addingTimeInterval(0.4)
            } else if Date() >= nextRepeat {
                nextRepeat = Date().addingTimeInterval(0.12)
                if let event = map.first(where: { $0.0 == held })?.1 { handler?(event) }
            }
        } else {
            heldDirection = nil
        }
    }
}

/// The PC list that drops down from the PC button
struct PCDropdown: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { model.closePC() }

            VStack(alignment: .leading, spacing: 6) {
                if !model.pairedHosts.isEmpty {
                    sectionTitle("Your PCs")
                    ForEach(model.pairedHosts) { host in
                        row("pc-host-\(host.id)",
                            title: host.name + (host.online ? "" : " · offline"),
                            symbol: host.id == model.selectedHost ? "checkmark" : "desktopcomputer") {
                            model.closePC()
                            model.onSelectHost?(host.id)
                        }
                    }
                }
                if !model.networkHosts.isEmpty {
                    sectionTitle("On Your Network")
                    ForEach(model.networkHosts) { host in
                        row("pc-net-\(host.id)", title: "\(host.name) · pair", symbol: "link") {
                            model.closePC()
                            model.onSelectHost?(host.id)
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                if let host = model.currentHost, host.paired {
                    row("pc-refresh", title: "Refresh Games", symbol: "arrow.clockwise") {
                        model.closePC()
                        model.hostAction("refresh", host)
                    }
                }
                row("pc-add", title: "Add PC by Address…", symbol: "plus") {
                    model.closePC()
                    model.command("addHost")
                }
            }
            .padding(12)
            .frame(width: 280)
            .modifier(PanelGlass(corner: 22))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 50)
        }
        .transition(.opacity)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private func row(_ id: String, title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gameFocus(id, scope: "pc", corner: 12, action: action)
    }
}

/// Game options as a navigable panel (used instead of the system menu when a controller is connected)
struct GameActionPanel: View {
    @ObservedObject var model: HomeModel
    let game: GameItem

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var destructive = false
    }

    private var items: [Item] {
        var list = [
            Item(id: "pin", title: game.pinned ? "Unpin" : "Pin", symbol: game.pinned ? "pin.slash" : "pin"),
            Item(id: "copyLink", title: "Copy Shortcut Link", symbol: "link"),
            Item(id: "saveIcon", title: "Save Icon to Photos", symbol: "photo"),
            Item(id: "editArtwork", title: "Edit Artwork…", symbol: "photo.on.rectangle.angled"),
            Item(id: "hide", title: game.hidden ? "Show Game" : "Hide Game", symbol: game.hidden ? "eye" : "eye.slash")
        ]
        if game.running {
            list.append(Item(id: "quit", title: "Quit Game", symbol: "xmark.circle", destructive: true))
        }
        return list
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { model.closeGameMenu() }

            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    Button { run(item.id) } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(item.destructive ? Color.red : Color.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .gameFocus("menu-\(item.id)", scope: "menu", corner: 12) { run(item.id) }
                }
            }
            .padding(14)
            .frame(width: 300)
            .modifier(PanelGlass(corner: 24))
        }
        .transition(.opacity)
    }

    private func run(_ id: String) {
        model.closeGameMenu()
        if id == "editArtwork" {
            model.editingGame = game
        } else {
            model.action(id, game)
        }
    }
}

struct PanelGlass: ViewModifier {
    let corner: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

/// Reports the scroll position so the tab bar can collapse when scrolling down
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ScrollOffsetReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("starlightScroll")).minY)
        }
        .frame(height: 0)
    }
}

extension View {
    func trackScroll(_ model: HomeModel) -> some View {
        self.coordinateSpace(name: "starlightScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { model.scrolled(to: $0) }
    }
}

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

// MARK: - Home tab

struct HomeTab: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var steam = SteamManager.shared
    @ObservedObject private var focus = GameFocus.shared
    @Namespace private var zoom
    /// 0 at the top → 1 after scrolling a little: fades "Play Now" into the navigation bar
    @State private var titleProgress: Double = 0

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 440
            let leading = geo.safeAreaInsets.leading + 24
            let trailing = geo.safeAreaInsets.trailing + 24
            Group {
                if let featured = model.featured {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: compact ? 14 : 22) {
                                FeaturedSection(game: featured, model: model, compact: compact)
                                    .padding(.leading, leading)
                                    .padding(.trailing, trailing)
                                    .id("section-featured")

                                if !model.continueGames.isEmpty {
                                    GameRow(id: "continue", title: "Continue Playing", games: model.continueGames, model: model,
                                            compact: compact, leadingInset: leading, trailingInset: trailing, zoom: zoom)
                                        .id("section-continue")
                                }

                                GameRow(id: "all", title: "Ready to Play", games: model.libraryGames, model: model,
                                        compact: compact, leadingInset: leading, trailingInset: trailing, zoom: zoom)
                                    .id("section-all")
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 40)
                        }
                        // Scroll across the full width so the rows reach the screen edges
                        .ignoresSafeArea(.container, edges: .horizontal)
                        .modifier(HomeScrollState(progress: $titleProgress))
                        .onChange(of: focus.focusedID) { id in
                            scroll(to: id, proxy: proxy)
                        }
                    }
                } else {
                    EmptyStateView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Behind the content (not beside it) so the navigation bar finds the scroll view
            // and draws its native scroll-edge effect, like Library and Settings
            .background(backdrop)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Play Now")
                    .font(.headline)
                    .opacity(model.featured != nil ? titleProgress : 0)
            }
        }
        .modifier(GameDetailDestination(model: model, tab: .home, zoom: zoom))
    }

    private func scroll(to id: String?, proxy: ScrollViewProxy) {
        guard let id = id else { return }
        let section: String?
        if id.hasPrefix("card-continue-") {
            section = "section-continue"
        } else if id.hasPrefix("card-all-") {
            section = "section-all"
        } else if id.hasPrefix("featured-") || id == "pc-button" || id == "search-button" {
            section = "section-featured"
        } else {
            section = nil
        }
        if let section = section {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(section, anchor: section == "section-featured" ? .top : .center)
            }
        }
    }

    private var backdrop: some View {
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

/// How far the Home list has moved from the top, as 0…1 over the first 60 pt (iOS 18+; earlier versions keep the bar empty).
/// Follows the finger continuously, like the system's own large-title collapse.
struct HomeScrollState: ViewModifier {
    @Binding var progress: Double

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Double.self) { geo in
                let offset = geo.contentOffset.y + geo.contentInsets.top
                return min(1, max(0, Double(offset - 8) / 60))
            } action: { _, value in
                progress = (value * 20).rounded() / 20
            }
        } else {
            content
        }
    }
}

struct FeaturedSection: View {
    let game: GameItem
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared
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
                    HStack(spacing: 8) {
                        Label(game.running ? "Resume" : "Play", systemImage: "play.fill")
                        if device.controllerConnected {
                            Image(systemName: PadGlyph.play)
                                .font(.system(size: 16, weight: .regular))
                                .opacity(0.6)
                        }
                    }
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

                // Always the system menu on touch. With a controller the button shows the Options glyph,
                // and pressing Options opens the navigable version (system menus can't be driven by a controller).
                Menu {
                    GameMenuItems(game: game, model: model)
                } label: {
                    Image(systemName: device.controllerConnected ? PadGlyph.options : "ellipsis")
                        .font(.system(size: device.controllerConnected ? 18 : 16, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .secondaryGlassButton()
                .accessibilityLabel("Game options")
            }
        }
        .padding(.top, compact ? 0 : 12)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !game.hostName.isEmpty { parts.append(game.hostName) }
        if let last = model.effectiveLastPlayed(game) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Played " + formatter.localizedString(for: last, relativeTo: Date()))
        } else {
            parts.append("Not played yet")
        }
        if let appid = game.steamAppId, let owned = SteamManager.shared.owned(appid), owned.playtimeForever > 0 {
            parts.append(SteamManager.formatPlaytime(owned.playtimeForever) + " in total")
        }
        return parts.joined(separator: " · ")
    }
}

struct GameRow: View {
    let id: String
    let title: String
    let games: [GameItem]
    @ObservedObject var model: HomeModel
    @ObservedObject private var focus = GameFocus.shared
    let compact: Bool
    var leadingInset: CGFloat = 24
    var trailingInset: CGFloat = 24
    var zoom: Namespace.ID? = nil
    var portrait: Bool = false

    private var prefix: String { "card-\(id)-" }
    @State private var scrolledID: String?

    /// Continue Playing only: tap / ✕ select the game; All Games opens its page
    private var selectsOnSwipe: Bool { id == "continue" }

    private func activate(_ game: GameItem) {
        if selectsOnSwipe {
            model.feature(game, row: id)
        } else {
            model.openDetail(game, source: prefix + game.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .padding(.leading, leadingInset)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: every card needs a frame for controller navigation
                    HStack(spacing: 14) {
                        ForEach(games) { game in
                            GameCard(game: game,
                                     selected: game.id == model.featured?.id && model.featuredRow == id,
                                     portrait: portrait,
                                     height: portrait ? (compact ? 150 : 180) : (compact ? 84 : 110))
                                .modifier(ZoomSource(id: prefix + game.id, zoom: zoom))
                                .onTapGesture { activate(game) }
                                .contextMenu { GameMenuItems(game: game, model: model) }
                                .gameFocus(prefix + game.id) { activate(game) }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .modifier(RowScrollTargetLayout())
                }
                .modifier(RowSnapping())
                .modifier(LeadingCardTracker(enabled: selectsOnSwipe, position: $scrolledID))
                .onChange(of: scrolledID) { cardID in
                    // Swiping Continue Playing selects the card that ends up first on the left
                    guard selectsOnSwipe, let cardID = cardID, cardID.hasPrefix(prefix),
                          Date().timeIntervalSince(model.lastControllerInput) > 1 else { return }
                    let gameId = String(cardID.dropFirst(prefix.count))
                    if let game = games.first(where: { $0.id == gameId }) {
                        model.feature(game, row: id)
                    }
                }
                .onChange(of: focus.focusedID) { focused in
                    guard let focused = focused, focused.hasPrefix(prefix) else { return }
                    let gameId = String(focused.dropFirst(prefix.count))
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(focused, anchor: .center)
                    }
                    // Moving onto a card features it, like tapping it
                    if model.featuredId != gameId || model.featuredRow != id {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.featuredId = gameId
                            model.featuredRow = id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Game page (opens with the native zoom transition from its card)

/// iOS 18: the card is the source of the zoom transition
struct ZoomSource: ViewModifier {
    let id: String
    let zoom: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let zoom = zoom {
            content.matchedTransitionSource(id: id, in: zoom)
        } else {
            content
        }
    }
}

struct ZoomDestination: ViewModifier {
    let id: String
    let zoom: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: zoom))
        } else {
            content
        }
    }
}

/// Pushes the game page in this tab's navigation stack
struct GameDetailDestination: ViewModifier {
    @ObservedObject var model: HomeModel
    let tab: StarlightTab
    let zoom: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.navigationDestination(isPresented: Binding(
                get: { model.detail?.tab == tab },
                set: { presented in
                    if !presented && model.detail?.tab == tab { model.detail = nil }
                }
            )) {
                if let route = model.detail, let game = model.games.first(where: { $0.id == route.gameId }) ?? Optional(route.game) {
                    GameDetailView(model: model, game: game)
                        .modifier(ZoomDestination(id: route.source, zoom: zoom))
                }
            }
        } else {
            content
        }
    }
}

struct GameDetailView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared
    @ObservedObject private var focus = GameFocus.shared
    let game: GameItem

    private struct Option: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var destructive = false
    }

    private var options: [Option] {
        var list = [
            Option(id: "pin", title: game.pinned ? "Unpin" : "Pin to App Icon", symbol: game.pinned ? "pin.slash" : "pin"),
            Option(id: "copyLink", title: "Copy Shortcut Link", symbol: "link"),
            Option(id: "saveIcon", title: "Save Icon to Photos", symbol: "photo"),
            Option(id: "editArtwork", title: "Edit Artwork…", symbol: "photo.on.rectangle.angled"),
            Option(id: "hide", title: game.hidden ? "Show Game" : "Hide Game", symbol: game.hidden ? "eye" : "eye.slash")
        ]
        if game.running {
            list.append(Option(id: "quit", title: "Quit Game", symbol: "xmark.circle", destructive: true))
        }
        return list
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

    var body: some View {
        GeometryReader { geo in
            let heroHeight = max(220, geo.size.height * 0.62)
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    hero(height: heroHeight)
                        .id("detail-top")

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            if !game.isInstalled {
                                Label("Not on this PC", systemImage: "icloud.and.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
                                    .modifier(PanelGlass(corner: 20))
                                    .gameFocus("detail-play", scope: "detail", corner: 20) {}
                            } else {
                            Button { model.launch(game) } label: {
                                HStack(spacing: 8) {
                                    Label(game.running ? "Resume" : "Play", systemImage: "play.fill")
                                    if device.controllerConnected {
                                        Image(systemName: PadGlyph.play)
                                            .font(.system(size: 16, weight: .regular))
                                            .opacity(0.6)
                                    }
                                }
                                .font(.system(size: 17, weight: .bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                            }
                            .primaryGlassButton()
                            .tint(.white)
                            .foregroundStyle(.black)
                            .gameFocus("detail-play", scope: "detail", corner: 24) { model.launch(game) }

                            if game.running {
                                Button(role: .destructive) { model.action("quit", game) } label: {
                                    Label("Quit", systemImage: "xmark")
                                        .font(.system(size: 17, weight: .semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                }
                                .secondaryGlassButton()
                                .tint(.red)
                                .gameFocus("detail-quit", scope: "detail", corner: 24) { model.action("quit", game) }
                            }

                            // Same native menu as on Home; with a controller, Options opens the navigable version
                            Menu {
                                GameMenuItems(game: game, model: model)
                            } label: {
                                Image(systemName: device.controllerConnected ? PadGlyph.options : "ellipsis")
                                    .font(.system(size: device.controllerConnected ? 18 : 16, weight: .semibold))
                                    .frame(width: 22, height: 26)
                            }
                            .secondaryGlassButton()
                            .accessibilityLabel("Game options")
                            }
                        }

                        if let appid = game.steamAppId {
                            SteamStatsSection(appid: appid)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
            .onChange(of: focus.focusedID) { focused in
                guard let focused = focused else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if focused == "detail-play" || focused == "detail-quit" {
                        proxy.scrollTo("detail-top", anchor: .top)
                    } else if focused.hasPrefix("ach-") {
                        proxy.scrollTo(focused, anchor: .center)
                    }
                }
            }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { GameFocus.shared.push("detail") }
        .onDisappear { GameFocus.shared.pop("detail") }
    }

    private func hero(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay(
                    ArtworkImage(path: game.heroPath ?? game.gridPath, fallbackText: "",
                                 remoteURL: game.steamAppId.flatMap { SteamManager.heroURL($0) })
                )
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if game.logoPath == nil, let appid = game.steamAppId, let url = SteamManager.logoURL(appid) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text(game.name).font(.system(size: 36, weight: .heavy)).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 380, maxHeight: 110, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                } else if let logo = ArtworkCache.shared.image(game.logoPath) {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 380, maxHeight: 110, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                        .accessibilityLabel(game.name)
                } else {
                    Text(game.name)
                        .font(.system(size: 36, weight: .heavy))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if game.running {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Running on PC").font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassCapsule()
                    }
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    private func run(_ id: String) {
        if id == "editArtwork" {
            model.editingGame = game
        } else {
            model.action(id, game)
            if id == "quit" || id == "hide" {
                model.closeDetail()
            }
        }
    }
}


/// iOS 17+: rows settle on a card edge, like the App Store
struct RowScrollTargetLayout: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTargetLayout()
        } else {
            content
        }
    }
}

/// iOS 17+: reports the card at the leading edge once a swipe settles
struct LeadingCardTracker: ViewModifier {
    let enabled: Bool
    @Binding var position: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), enabled {
            content.scrollPosition(id: $position, anchor: .leading)
        } else {
            content
        }
    }
}

struct RowSnapping: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTargetBehavior(.viewAligned)
        } else {
            content
        }
    }
}

struct GameCard: View {
    let game: GameItem
    let selected: Bool
    let portrait: Bool
    let height: CGFloat
    var showsReadyBadge = false

    var body: some View {
        let width = portrait ? height * 2 / 3 : height * 16 / 9
        ZStack(alignment: .bottomLeading) {
            // Portrait cards: the portrait cover. Landscape cards: the same background as the Home screen, plus the logo
            ArtworkImage(path: portrait ? game.gridPath : (game.heroPath ?? game.gridPath), fallbackText: game.name,
                         remoteURL: game.steamAppId.flatMap { portrait ? SteamManager.coverURL($0) : SteamManager.heroURL($0) })
                .frame(width: width, height: height)
                .clipped()

            if showsReadyBadge && game.isInstalled {
                Text("Ready to Play")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green, in: Capsule())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if !portrait {
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
    @ObservedObject private var steam = SteamManager.shared
    @Namespace private var zoom
    @State private var filter: GameCollection.Filter = .all
    @State private var sort: GameCollection.Sort = .name

    var body: some View {
        let entries = GameCollection.entries(model: model, steam: steam)
        let shown = GameCollection.apply(entries, filter: filter, sort: sort, steam: steam, model: model)
        Group {
            if entries.isEmpty {
                EmptyStateView(model: model)
            } else {
                GameGrid(prefix: "lib", games: shown, model: model, zoom: zoom, showsReadyBadge: true) {
                    HStack(spacing: 12) {
                        Picker("Show", selection: $filter) {
                            ForEach(GameCollection.Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                ForEach(GameCollection.Sort.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .secondaryGlassButton()
                        Spacer(minLength: 0)
                        Text("\(shown.count) games")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .modifier(GameDetailDestination(model: model, tab: .library, zoom: zoom))
    }
}

/// Portrait covers in a lazy grid (Library and Search can hold hundreds of Steam games).
/// Controller moves are index-based, so covers off screen are still reachable.
struct GameGrid<Header: View>: View {
    let prefix: String
    let games: [GameItem]
    @ObservedObject var model: HomeModel
    var zoom: Namespace.ID? = nil
    var showsReadyBadge = false
    @ViewBuilder var header: () -> Header
    @ObservedObject private var focus = GameFocus.shared

    private let cardWidth: CGFloat = 120
    private let spacing: CGFloat = 18

    private var columns: Int {
        let width = UIScreen.main.bounds.width - 100
        return max(2, Int((width + spacing) / (cardWidth + spacing)))
    }

    var body: some View {
        let _ = focus.registerGrid(prefix, ids: games.map { "\(prefix)-\($0.id)" }, columns: columns)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header()
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: columns),
                              alignment: .leading, spacing: 18) {
                        ForEach(games) { game in
                            let focusID = "\(prefix)-\(game.id)"
                            VStack(alignment: .leading, spacing: 6) {
                                GameCard(game: game, selected: false, portrait: true, height: 180, showsReadyBadge: showsReadyBadge)
                                    .modifier(ZoomSource(id: focusID, zoom: zoom))
                                    .gameFocus(focusID) { model.openDetail(game, source: focusID) }
                                Text(game.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .frame(width: cardWidth)
                            .onTapGesture { model.openDetail(game, source: focusID) }
                            .contextMenu {
                                if game.isInstalled { GameMenuItems(game: game, model: model) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focus.focusedID) { focused in
                guard let focused = focused, focused.hasPrefix("\(prefix)-") else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(focused, anchor: .center)
                }
            }
        }
    }
}

extension GameGrid where Header == EmptyView {
    init(prefix: String, games: [GameItem], model: HomeModel, zoom: Namespace.ID? = nil, showsReadyBadge: Bool = false) {
        self.init(prefix: prefix, games: games, model: model, zoom: zoom, showsReadyBadge: showsReadyBadge, header: { EmptyView() })
    }
}

// MARK: - Search

struct SearchTab: View {
    @ObservedObject var model: HomeModel
    @Namespace private var zoom

    @ObservedObject private var steam = SteamManager.shared

    private var results: [GameItem] {
        let all = GameCollection.apply(GameCollection.entries(model: model, steam: steam),
                                       filter: .all, sort: .name, steam: steam, model: model)
        let trimmed = model.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if model.games.isEmpty {
                EmptyStateView(model: model)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No games match \u{201C}\(model.searchQuery)\u{201D}")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GameGrid(prefix: "search", games: results, model: model, zoom: zoom, showsReadyBadge: true)
            }
        }
        .modifier(GameDetailDestination(model: model, tab: .search, zoom: zoom))
    }
}

// MARK: - Settings tab

struct SettingsTab: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var steam = SteamManager.shared
    /// The screen pushed from the root (also set by ✕ on the controller)
    @State private var route: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
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
                            Button { model.hostAction("refresh", host) } label: {
                                Label("Refresh Games", systemImage: "arrow.clockwise")
                            }
                            .settingsFocus("pc-refresh", scope: scope) { model.hostAction("refresh", host) }
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

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    SecureField(model.artworkConfigured ? "New API key (optional)" : "SteamGridDB API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyFocused)
                        .settingsFocus("art-key", scope: scope) { keyFocused = true }
                    Button(action: saveKey) {
                        Label(model.artworkConfigured ? "Download Missing Artwork" : "Save Key & Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.artworkConfigured && key.isEmpty)
                    .settingsFocus("art-save", scope: scope) {
                        if model.artworkConfigured || !key.isEmpty { saveKey() }
                    }
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
                        .settingsFocus("art-redownload", scope: scope) { model.onArtworkCommand?("redownload", "") }
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label(removeArmed ? "Press again to remove" : "Remove Key & Artwork", systemImage: "trash")
                        }
                        .settingsFocus("art-remove", scope: scope) {
                            if removeArmed {
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
                footer: "Fills the Home screen and the loading screen, and is used for the game cards in Continue Playing and All Games."),
        ArtKind(kind: "grid", title: "Portrait Cover", aspect: 2.0 / 3.0,
                footer: "Vertical cover with the logo built in, used in Library."),
        ArtKind(kind: "logo", title: "Logo", aspect: 2.0,
                footer: "Shown over the background on the Home screen and on the game cards."),
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

    /// "resume", "keyboard", "stats", "disconnect", "quit"
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

    /// Controller input: "up", "down", "select", "back"
    @objc func navigate(_ action: String) {
        state.navigate(action)
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

    let gameName: String
    @Published var statsVisible: Bool
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
        return [
            Item(id: "resume", title: "Back to Game", symbol: "play.fill", prominent: true),
            Item(id: "keyboard", title: "Keyboard", symbol: "keyboard"),
            Item(id: "stats", title: statsVisible ? "Hide Statistics" : "Show Statistics", symbol: "chart.bar.xaxis"),
            Item(id: "disconnect", title: "Stop Streaming", symbol: "stop.fill"),
            Item(id: "askQuit", title: "Quit Game", symbol: "xmark.circle.fill", destructive: true)
        ]
    }

    func activate(_ id: String) {
        switch id {
        case "askQuit":
            confirmQuit = true
            focus = 1   // Cancel first, so a stray press doesn't quit
        case "cancelQuit":
            confirmQuit = false
            focus = items.firstIndex { $0.id == "askQuit" } ?? 0
        default:
            onAction?(id)
        }
    }

    func navigate(_ action: String) {
        let count = items.count
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "select":
            if items.indices.contains(focus) { activate(items[focus].id) }
        case "back":
            if confirmQuit { activate("cancelQuit") } else { onAction?("resume") }
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
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.confirmQuit ? "Quit \(state.gameName)?" : state.gameName)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(2)
            if state.confirmQuit {
                Text("The game closes on your PC. Unsaved progress may be lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 4)

            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                if item.id == "disconnect" {
                    Spacer(minLength: 8)
                }
                menuButton(item, focused: device.controllerConnected && index == state.focus)
                if item.id == "disconnect" {
                    Text("The game keeps running on your PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            if state.confirmQuit {
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 300)
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

// MARK: - Steam (foundations: account, owned games, recently played)

/// Stores the Steam Web API key in the iPhone's Keychain (never in UserDefaults or the repo)
enum SteamKeychain {
    private static let service = "Starlight.Steam"
    private static let account = "WebAPIKey"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(key.utf8)
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct SteamOwnedGame: Codable, Equatable {
    let appid: Int
    let name: String
    /// Minutes
    let playtimeForever: Int
    let lastPlayed: Date?
}

struct SteamRecentGame: Codable, Equatable {
    let appid: Int
    let name: String
    /// Minutes in the last two weeks
    let playtimeTwoWeeks: Int
    let playtimeForever: Int
}

struct SteamCache: Codable {
    var steamID: String
    var personaName: String
    var profilePublic: Bool
    var owned: [SteamOwnedGame]
    var recent: [SteamRecentGame]
    var updated: Date
}

/// Talks to the Steam Web API and keeps a local cache. Used by the game page and Home in later releases.
final class SteamManager: ObservableObject {
    static let shared = SteamManager()

    @Published private(set) var cache: SteamCache?
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasKey = SteamKeychain.load() != nil
    @Published private(set) var achievements: [Int: SteamAppStats] = [:]
    private var loadingAchievements: Set<Int> = []

    private static let steamIDKey = "StarlightSteamID"
    private static let staleAfter: TimeInterval = 3 * 60 * 60

    var steamID: String? { UserDefaults.standard.string(forKey: Self.steamIDKey) }
    var isConfigured: Bool { hasKey && steamID != nil }
    var keySuffix: String {
        guard let key = SteamKeychain.load(), key.count >= 4 else { return "" }
        return String(key.suffix(4))
    }

    /// Owned games by appid
    func owned(_ appid: Int) -> SteamOwnedGame? { cache?.owned.first { $0.appid == appid } }
    func recent(_ appid: Int) -> SteamRecentGame? { cache?.recent.first { $0.appid == appid } }

    private init() {
        cache = Self.loadCache()
    }

    // MARK: Setup

    /// Saves the key (if given) and the profile, then checks them by downloading the games
    @MainActor
    func configure(apiKey: String, profile: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            SteamKeychain.save(key)
            hasKey = true
        }
        guard let storedKey = SteamKeychain.load() else {
            errorMessage = "Enter your Steam Web API key."
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let input = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = steamID
            if !input.isEmpty {
                id = try await resolveSteamID(input, key: storedKey)
            }
            guard let resolved = id else {
                errorMessage = "Enter your SteamID64 or profile name."
                return
            }
            UserDefaults.standard.set(resolved, forKey: Self.steamIDKey)
            try await refresh(key: storedKey, steamID: resolved)
        } catch {
            errorMessage = (error as? SteamError)?.message ?? "Couldn't reach Steam. Check your connection and try again."
        }
    }

    @MainActor
    func refreshIfStale() {
        guard isConfigured else { return }
        if let updated = cache?.updated, Date().timeIntervalSince(updated) < Self.staleAfter { return }
        Task { await refreshNow() }
    }

    @MainActor
    func refreshNow() async {
        guard let key = SteamKeychain.load(), let id = steamID, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await refresh(key: key, steamID: id)
        } catch {
            errorMessage = (error as? SteamError)?.message ?? "Couldn't reach Steam. Check your connection and try again."
        }
    }

    @MainActor
    func remove() {
        achievements = [:]
        SteamKeychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.steamIDKey)
        hasKey = false
        cache = nil
        errorMessage = nil
        try? FileManager.default.removeItem(at: Self.cacheURL.deletingLastPathComponent())
    }

    // MARK: Steam Web API

    struct SteamError: Error {
        let message: String
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.steampowered.com/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw SteamError(message: "Steam rejected the API key. Check it at steamcommunity.com/dev/apikey.")
        }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SteamError(message: "Steam didn't answer as expected (HTTP \(status)). Try again later.")
        }
        return json
    }

    /// Accepts a SteamID64, a profile URL (/profiles/… or /id/…) or a custom profile name
    private func resolveSteamID(_ input: String, key: String) async throws -> String {
        var text = input
        if let range = text.range(of: "/profiles/") {
            text = String(text[range.upperBound...]).components(separatedBy: "/").first ?? ""
        } else if let range = text.range(of: "/id/") {
            text = String(text[range.upperBound...]).components(separatedBy: "/").first ?? ""
        }
        if text.count == 17, text.allSatisfy(\.isNumber) {
            return text
        }
        let json = try await get("ISteamUser/ResolveVanityURL/v1/", ["key": key, "vanityurl": text])
        let response = json["response"] as? [String: Any]
        if (response?["success"] as? Int) == 1, let id = response?["steamid"] as? String {
            return id
        }
        throw SteamError(message: "No Steam profile called \u{201C}\(text)\u{201D}. Use your SteamID64 or the name in your profile URL.")
    }

    @MainActor
    private func refresh(key: String, steamID: String) async throws {
        // Profile name and visibility
        let summary = try await get("ISteamUser/GetPlayerSummaries/v2/", ["key": key, "steamids": steamID])
        let players = (summary["response"] as? [String: Any])?["players"] as? [[String: Any]] ?? []
        guard let player = players.first else {
            throw SteamError(message: "Steam couldn't find that account.")
        }
        let personaName = player["personaname"] as? String ?? "Steam"

        let ownedJSON = try await get("IPlayerService/GetOwnedGames/v1/", [
            "key": key, "steamid": steamID, "include_appinfo": "1", "include_played_free_games": "1"
        ])
        let ownedResponse = ownedJSON["response"] as? [String: Any] ?? [:]
        // A private "Game details" setting returns an empty response
        let profilePublic = ownedResponse["game_count"] != nil
        let owned: [SteamOwnedGame] = (ownedResponse["games"] as? [[String: Any]] ?? []).compactMap { game in
            guard let appid = game["appid"] as? Int else { return nil }
            let last = (game["rtime_last_played"] as? Double) ?? 0
            return SteamOwnedGame(appid: appid,
                                  name: game["name"] as? String ?? "",
                                  playtimeForever: game["playtime_forever"] as? Int ?? 0,
                                  lastPlayed: last > 0 ? Date(timeIntervalSince1970: last) : nil)
        }

        let recentJSON = try await get("IPlayerService/GetRecentlyPlayedGames/v1/", ["key": key, "steamid": steamID])
        let recent: [SteamRecentGame] = ((recentJSON["response"] as? [String: Any])?["games"] as? [[String: Any]] ?? []).compactMap { game in
            guard let appid = game["appid"] as? Int else { return nil }
            return SteamRecentGame(appid: appid,
                                   name: game["name"] as? String ?? "",
                                   playtimeTwoWeeks: game["playtime_2weeks"] as? Int ?? 0,
                                   playtimeForever: game["playtime_forever"] as? Int ?? 0)
        }

        let newCache = SteamCache(steamID: steamID, personaName: personaName, profilePublic: profilePublic,
                                  owned: owned, recent: recent, updated: Date())
        cache = newCache
        Self.saveCache(newCache)
        if !profilePublic {
            errorMessage = "Connected, but your Steam “Game details” are private, so playtime and achievements are empty. Set them to Public in Steam › Profile › Privacy Settings."
        }
    }

    // MARK: Achievements

    /// Player progress + names/icons + global rarity for one game, cached for a few hours
    @MainActor
    func loadAchievements(_ appid: Int) async {
        if let cached = achievements[appid], Date().timeIntervalSince(cached.updated) < Self.staleAfter { return }
        if let stored = Self.loadStats(appid), Date().timeIntervalSince(stored.updated) < Self.staleAfter {
            achievements[appid] = stored
            return
        }
        guard let key = SteamKeychain.load(), let id = steamID, !loadingAchievements.contains(appid) else { return }
        loadingAchievements.insert(appid)
        defer { loadingAchievements.remove(appid) }

        let app = String(appid)
        // Games without achievements answer with an error: that just means an empty list
        let player = (try? await get("ISteamUserStats/GetPlayerAchievements/v1/", ["key": key, "steamid": id, "appid": app, "l": "english"])) ?? [:]
        let schema = (try? await get("ISteamUserStats/GetSchemaForGame/v2/", ["key": key, "appid": app, "l": "english"])) ?? [:]
        let global = (try? await get("ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/", ["gameid": app])) ?? [:]

        var progress: [String: (Bool, Date?)] = [:]
        for item in ((player["playerstats"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []) {
            guard let name = item["apiname"] as? String else { continue }
            let time = (item["unlocktime"] as? Double) ?? 0
            progress[name] = (((item["achieved"] as? Int) ?? 0) == 1, time > 0 ? Date(timeIntervalSince1970: time) : nil)
        }
        var rarity: [String: Double] = [:]
        for item in ((global["achievementpercentages"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []) {
            guard let name = item["name"] as? String else { continue }
            if let value = item["percent"] as? Double {
                rarity[name] = value
            } else if let text = item["percent"] as? String, let value = Double(text) {
                rarity[name] = value
            }
        }
        let definitions = ((schema["game"] as? [String: Any])?["availableGameStats"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []
        let list: [SteamAchievement] = definitions.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let state = progress[name]
            return SteamAchievement(id: name,
                                    name: item["displayName"] as? String ?? name,
                                    description: item["description"] as? String ?? "",
                                    hidden: ((item["hidden"] as? Int) ?? 0) == 1,
                                    icon: item["icon"] as? String ?? "",
                                    iconGray: item["icongray"] as? String ?? "",
                                    achieved: state?.0 ?? false,
                                    unlocked: state?.1,
                                    percent: rarity[name])
        }
        let stats = SteamAppStats(appid: appid, achievements: list, updated: Date())
        achievements[appid] = stats
        Self.saveStats(stats)
    }

    private static func statsURL(_ appid: Int) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("achievements-\(appid).json")
    }

    private static func loadStats(_ appid: Int) -> SteamAppStats? {
        guard let data = try? Data(contentsOf: statsURL(appid)) else { return nil }
        return try? JSONDecoder().decode(SteamAppStats.self, from: data)
    }

    private static func saveStats(_ stats: SteamAppStats) {
        let url = statsURL(stats.appid)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stats) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Steam/cache.json")
    }

    private static func loadCache() -> SteamCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(SteamCache.self, from: data)
    }

    private static func saveCache(_ cache: SteamCache) {
        let url = cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct SteamSettingsRow: View {
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        HStack {
            Label("Steam", systemImage: "person.crop.circle")
            Spacer()
            Text(steam.isConfigured ? (steam.cache?.personaName ?? "Connected") : "Not set up")
                .foregroundStyle(.secondary)
        }
    }
}

struct SteamSettingsView: View {
    @ObservedObject private var steam = SteamManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var profile = ""
    @State private var confirmRemove = false
    @State private var removeArmed = false
    @FocusState private var field: Int?
    @ObservedObject private var focus = GameFocus.shared
    private let scope = "settings-steam"

    private var canConnect: Bool {
        !steam.busy && (steam.hasKey || !key.isEmpty) && (steam.steamID != nil || !profile.isEmpty)
    }

    private func connect() {
        let enteredKey = key
        let enteredProfile = profile
        Task {
            await steam.configure(apiKey: enteredKey, profile: enteredProfile)
            if steam.errorMessage == nil || steam.cache != nil {
                key = ""
                profile = ""
            }
        }
    }

    private var updatedText: String {
        guard let date = steam.cache?.updated else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                SecureField(steam.hasKey ? "New API key (optional)" : "Steam Web API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: 0)
                    .settingsFocus("steam-key", scope: scope) { field = 0 }
                TextField(steam.steamID ?? "SteamID64 or profile name", text: $profile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: 1)
                    .settingsFocus("steam-profile", scope: scope) { field = 1 }
                Button(action: connect) {
                    HStack {
                        Label(steam.isConfigured ? "Save & Test" : "Connect", systemImage: "checkmark.circle")
                        if steam.busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canConnect)
                .settingsFocus("steam-connect", scope: scope) { if canConnect { connect() } }
            } header: {
                Text("Steam account")
            } footer: {
                Text("Get a key at steamcommunity.com/dev/apikey (sign in; any domain name works). For your SteamID, paste your profile URL or the name in it. Your profile's \u{201C}Game details\u{201D} must be Public for playtime and achievements. The key is stored only in this iPhone's Keychain.")
            }

            if let error = steam.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if steam.isConfigured {
                Section("Status") {
                    row("Account", steam.cache?.personaName ?? "—")
                    row("SteamID", steam.steamID ?? "—")
                    row("API key", "…" + steam.keySuffix)
                    row("Games owned", steam.cache.map { "\($0.owned.count)" } ?? "—")
                    row("Played in the last 2 weeks", steam.cache.map { "\($0.recent.count)" } ?? "—")
                    row("Updated", updatedText)
                }
                Section {
                    Button {
                        Task { await steam.refreshNow() }
                    } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(steam.busy)
                    .settingsFocus("steam-refresh", scope: scope) { Task { await steam.refreshNow() } }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label(removeArmed ? "Press again to disconnect" : "Disconnect Steam", systemImage: "trash")
                    }
                    .settingsFocus("steam-remove", scope: scope) {
                        if removeArmed {
                            steam.remove()
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
        .navigationTitle("Steam")
        .onChange(of: field) { focus.textEditing = $0 != nil }
        .settingsScreen(scope, dismiss: dismiss)
        .onChange(of: focus.focusedID) { id in
            if id != "steam-remove" { removeArmed = false }
        }
        .confirmationDialog("Disconnect Steam? The API key and the downloaded data are removed from this iPhone.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { steam.remove() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Steam achievements and collection helpers

struct SteamAchievement: Codable, Identifiable, Equatable {
    let id: String          // API name
    let name: String
    let description: String
    let hidden: Bool
    let icon: String
    let iconGray: String
    let achieved: Bool
    let unlocked: Date?
    let percent: Double?
}

struct SteamAppStats: Codable, Equatable {
    let appid: Int
    let achievements: [SteamAchievement]
    let updated: Date

    var unlockedCount: Int { achievements.filter(\.achieved).count }
}

extension SteamManager {
    static func formatPlaytime(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
    }

    /// Steam's own artwork for games that aren't on the PC (no key needed)
    static func coverURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg") }
    static func heroURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_hero.jpg") }
    static func logoURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/logo.png") }
}

/// Library / Search entries: everything on the PC plus every Steam game you own, merged by appid
enum GameCollection {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", ready = "Ready to Play", notInstalled = "Not Installed"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", recent = "Recently Played", playtime = "Most Played"
        var id: String { rawValue }
    }

    static func entries(model: HomeModel, steam: SteamManager) -> [GameItem] {
        let installed = model.libraryGames
        let installedSteamIds = Set(model.games.compactMap(\.steamAppId))
        let steamOnly = (steam.cache?.owned ?? [])
            .filter { !installedSteamIds.contains($0.appid) }
            .map { GameItem.steamOnly(appid: $0.appid, name: $0.name) }
        return installed + steamOnly
    }

    static func apply(_ entries: [GameItem], filter: Filter, sort: Sort, steam: SteamManager, model: HomeModel) -> [GameItem] {
        let filtered: [GameItem]
        switch filter {
        case .all: filtered = entries
        case .ready: filtered = entries.filter(\.isInstalled)
        case .notInstalled: filtered = entries.filter { !$0.isInstalled }
        }
        func playtime(_ game: GameItem) -> Int { game.steamAppId.flatMap { steam.owned($0)?.playtimeForever } ?? 0 }
        func last(_ game: GameItem) -> Date { model.effectiveLastPlayed(game) ?? .distantPast }
        return filtered.sorted { a, b in
            switch sort {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .recent:
                let (x, y) = (last(a), last(b))
                return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .playtime:
                let (x, y) = (playtime(a), playtime(b))
                return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// Playtime and achievements on the game page (Steam games only)
struct SteamStatsSection: View {
    let appid: Int
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let owned = steam.owned(appid) {
                HStack(spacing: 22) {
                    stat(SteamManager.formatPlaytime(owned.playtimeForever), "Played")
                    if let recent = steam.recent(appid), recent.playtimeTwoWeeks > 0 {
                        stat(SteamManager.formatPlaytime(recent.playtimeTwoWeeks), "Last 2 weeks")
                    }
                    if let last = owned.lastPlayed {
                        stat(last.formatted(date: .abbreviated, time: .omitted), "Last played")
                    }
                }
            }

            if let stats = steam.achievements[appid] {
                if !stats.achievements.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Achievements")
                                .font(.system(size: 17, weight: .bold))
                            Spacer()
                            Text("\(stats.unlockedCount) of \(stats.achievements.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(stats.unlockedCount), total: Double(max(stats.achievements.count, 1)))
                            .tint(starlightGold)
                    }
                    .frame(maxWidth: 560)

                    ForEach(sorted(stats.achievements)) { achievement in
                        AchievementRow(achievement: achievement)
                            .gameFocus("ach-\(achievement.id)", scope: "detail", corner: 14) {}
                    }
                }
            } else if steam.isConfigured {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading Steam stats…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: appid) { await steam.loadAchievements(appid) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Unlocked first (most recent first), then locked from most to least common
    private func sorted(_ list: [SteamAchievement]) -> [SteamAchievement] {
        list.sorted { a, b in
            if a.achieved != b.achieved { return a.achieved }
            if a.achieved { return (a.unlocked ?? .distantPast) > (b.unlocked ?? .distantPast) }
            return (a.percent ?? 0) > (b.percent ?? 0)
        }
    }
}

struct AchievementRow: View {
    let achievement: SteamAchievement

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: achievement.achieved ? achievement.icon : achievement.iconGray)) { phase in
                if let image = phase.image {
                    image.resizable()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.hidden && !achievement.achieved ? "Hidden achievement" : achievement.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(achievement.achieved ? .white : .white.opacity(0.7))
                if !(achievement.hidden && !achievement.achieved), !achievement.description.isEmpty {
                    Text(achievement.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if achievement.achieved, let date = achievement.unlocked {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12, weight: .semibold))
                }
                if let percent = achievement.percent {
                    Text(String(format: "%.1f%% of players", percent))
                        .font(.system(size: 11.5))
                        .foregroundStyle(percent < 10 ? starlightGold : .secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 560)
        .modifier(PanelGlass(corner: 14))
        .accessibilityElement(children: .combine)
    }
}
