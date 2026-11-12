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

    // Navigation state
    @Published var tab: StarlightTab = .home
    var previousTab: StarlightTab = .home
    @Published var pcExpanded = false
    @Published var gameMenu: GameItem?
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
            previousTab = tab
            tab = newTab
            tabBarCollapsedByScroll = false
            lastScrollOffset = 0
            GameFocus.shared.focusedID = nil
        }
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
            previousTab = tab
            tab = .search
        }
        if fromController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { GameFocus.shared.focus("search-field") }
        } else {
            searchFieldFocused = true
        }
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
        select(tabs[(index + delta + tabs.count) % tabs.count])
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

    /// Controller input on the Starlight screens
    func handlePad(_ event: GamepadInput.Event) {
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
            if searchFieldFocused {
                searchFieldFocused = false
            } else if gameMenu != nil {
                closeGameMenu()
            } else if pcExpanded {
                closePC()
            } else if tabBarFocused {
                unfocusTabBar()
            } else if tab == .search {
                select(previousTab == .search ? .home : previousTab)
            }
        case .search: openSearch(fromController: true)
        case .pc: togglePC()
        case .options:
            if tabBarFocused { unfocusTabBar() } else { focusTabBar() }
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

    /// The tabs shown in the tab bar (Search has its own button at the top)
    static let barTabs: [StarlightTab] = [.home, .library, .settings]
}

struct HomeRootView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var focus = GameFocus.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    TopBar(model: model)
                }

            StarlightTabBar(model: model)
                .padding(.leading, 20)
                .padding(.bottom, 6)

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

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .home: HomeTab(model: model)
        case .library: LibraryTab(model: model)
        case .settings: SettingsTab(model: model)
        case .search: SearchTab(model: model)
        }
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

    var activeScope: String { scopes.last ?? "main" }

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
    @ObservedObject private var focus = GameFocus.shared
    @ObservedObject private var device = DeviceStatus.shared

    func body(content: Content) -> some View {
        let _ = focus.register(id, action)
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
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .id(id)
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

    enum Event { case up, down, left, right, confirm, back, search, pc, options, previousTab, nextTab }

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

        let pressed = down.subtracting(previous)
        previous = down

        let map: [(String, Event)] = [
            ("up", .up), ("down", .down), ("left", .left), ("right", .right),
            ("a", .confirm), ("b", .back), ("y", .search), ("x", .pc),
            ("menu", .options), ("l1", .previousTab), ("r1", .nextTab)
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

// MARK: - Top bar: PC, search, status

struct TopBar: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        HStack(spacing: 10) {
            PCButton(model: model)
            SearchButton(model: model)
            Spacer(minLength: 8)
            StatusCluster()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

struct PCButton: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared

    var body: some View {
        Button { model.togglePC() } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 17, weight: .semibold))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                        .offset(x: 3, y: 2)
                }
                if model.pcExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentHost?.name ?? "Choose a PC")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if device.controllerConnected {
                    Image(systemName: PadGlyph.pc)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: model.pcExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .glassCapsule()
        }
        .buttonStyle(.plain)
        .gameFocus("pc-button", corner: 20) { model.togglePC() }
        .accessibilityLabel("PC: \(model.currentHost?.name ?? "none"), \(statusText)")
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.pcExpanded)
    }

    private var statusColor: Color {
        guard let host = model.currentHost else { return .gray }
        if !host.paired { return .orange }
        return host.online ? .green : .gray
    }

    private var statusText: String {
        guard let host = model.currentHost else { return model.hosts.isEmpty ? "No PCs yet" : "Tap to choose" }
        return !host.paired ? "Not paired" : (host.online ? "Online" : "Offline")
    }
}

struct SearchButton: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared

    var body: some View {
        Button { model.openSearch(fromController: false) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                Text("Search game")
                    .font(.system(size: 15, weight: .semibold))
                if device.controllerConnected {
                    Image(systemName: PadGlyph.search)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassCapsule()
        }
        .buttonStyle(.plain)
        .gameFocus("search-button", corner: 20) { model.openSearch(fromController: true) }
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
            .padding(.leading, 20)
            .padding(.top, 56)
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

// MARK: - Tab bar

/// Home / Library / Settings. Collapses to the current tab's icon when scrolling down or when a
/// controller is connected (then it also shows the Options glyph). Options focuses it, L1/R1 switch tabs.
struct StarlightTabBar: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared

    private var expanded: Bool {
        if model.tabBarFocused || model.tabBarFlash { return true }
        if device.controllerConnected { return false }
        return !model.tabBarCollapsedByScroll
    }

    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 4) {
                    if device.controllerConnected {
                        Image(systemName: PadGlyph.leftShoulder)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    ForEach(StarlightTab.barTabs, id: \.self) { tab in
                        Button { model.select(tab) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.symbol)
                                Text(tab.title)
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.tab == tab ? starlightGold : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(model.tab == tab ? Color.white.opacity(0.14) : .clear, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .gameFocus("tab-\(tab.rawValue)", scope: "tabbar", corner: 20) { model.select(tab) }
                    }
                    if device.controllerConnected {
                        Image(systemName: PadGlyph.rightShoulder)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(5)
                .glassCapsule()
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            } else {
                Button { model.expandTabBar() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(starlightGold)
                        if device.controllerConnected {
                            Image(systemName: PadGlyph.options)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .glassCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.tab.title) tab, show tabs")
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expanded)
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
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassCapsule()
    }
}

// MARK: - Shared pieces

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
    @ObservedObject private var focus = GameFocus.shared

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 440
            ZStack(alignment: .top) {
                backdrop

                if let featured = model.featured {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: compact ? 14 : 22) {
                                ScrollOffsetReader()

                                FeaturedSection(game: featured, model: model, compact: compact)
                                    .id("section-featured")

                                GameRow(id: "continue", title: "Continue Playing", games: model.continueGames, model: model, compact: compact)
                                    .id("section-continue")

                                GameRow(id: "all", title: "All Games", games: model.libraryGames, model: model, compact: compact)
                                    .id("section-all")
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
                            .padding(.bottom, 90)
                        }
                        .trackScroll(model)
                        .onChange(of: focus.focusedID) { id in
                            scroll(to: id, proxy: proxy)
                        }
                    }
                } else {
                    EmptyStateView(model: model)
                }
            }
        }
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
                    Label(game.running ? "Resume" : "Play", systemImage: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .primaryGlassButton()
                .tint(.white)
                .foregroundStyle(.black)
                .gameFocus("featured-play", corner: 22) { model.launch(game) }

                if game.running {
                    Button(role: .destructive) { model.action("quit", game) } label: {
                        Label("Quit", systemImage: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .secondaryGlassButton()
                    .tint(.red)
                    .gameFocus("featured-quit", corner: 22) { model.action("quit", game) }
                }

                if device.controllerConnected {
                    Button { model.openGameMenu(game) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .secondaryGlassButton()
                    .gameFocus("featured-more", corner: 22) { model.openGameMenu(game) }
                    .accessibilityLabel("Game options")
                } else {
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
        }
        .padding(.top, compact ? 0 : 12)
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
    @ObservedObject private var focus = GameFocus.shared
    let compact: Bool
    var portrait: Bool = false

    private var prefix: String { "card-\(id)-" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: every card needs a frame for controller navigation
                    HStack(spacing: 14) {
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
                                .gameFocus(prefix + game.id) { model.launch(game) }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
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

struct GameCard: View {
    let game: GameItem
    let selected: Bool
    let portrait: Bool
    let height: CGFloat

    var body: some View {
        let width = portrait ? height * 2 / 3 : height * 16 / 9
        ZStack(alignment: .bottomLeading) {
            // Portrait cards: the portrait cover. Landscape cards: the same background as the Home screen, plus the logo
            ArtworkImage(path: portrait ? game.gridPath : (game.heroPath ?? game.gridPath), fallbackText: game.name)
                .frame(width: width, height: height)
                .clipped()

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

    var body: some View {
        Group {
            if model.games.isEmpty {
                EmptyStateView(model: model)
            } else {
                GameGrid(prefix: "lib", games: model.libraryGames, model: model)
            }
        }
    }
}

/// Portrait covers in a grid (Library and Search). Not lazy, so every cover can be reached with the controller.
struct GameGrid: View {
    let prefix: String
    let games: [GameItem]
    @ObservedObject var model: HomeModel
    @ObservedObject private var focus = GameFocus.shared

    private let cardWidth: CGFloat = 120
    private let spacing: CGFloat = 18

    private var columns: Int {
        let width = UIScreen.main.bounds.width - 100
        return max(2, Int((width + spacing) / (cardWidth + spacing)))
    }

    private var rows: [[GameItem]] {
        stride(from: 0, to: games.count, by: columns).map { Array(games[$0..<min($0 + columns, games.count)]) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ScrollOffsetReader()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(row) { game in
                                VStack(alignment: .leading, spacing: 6) {
                                    GameCard(game: game, selected: false, portrait: true, height: 180)
                                        .gameFocus("\(prefix)-\(game.id)") { model.launch(game) }
                                    Text(game.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: cardWidth)
                                .onTapGesture { model.launch(game) }
                                .contextMenu { GameMenuItems(game: game, model: model) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .trackScroll(model)
            .onChange(of: focus.focusedID) { focused in
                guard let focused = focused, focused.hasPrefix("\(prefix)-") else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(focused, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Search

struct SearchTab: View {
    @ObservedObject var model: HomeModel
    @FocusState private var fieldFocused: Bool

    private var results: [GameItem] {
        let all = model.libraryGames
        let trimmed = model.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Games on \(model.currentHost?.name ?? "your PC")", text: $model.searchQuery)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { model.searchFieldFocused = false }
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassCapsule()
            .gameFocus("search-field", corner: 22) { model.searchFieldFocused = true }
            .padding(.horizontal, 24)
            .padding(.top, 4)

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
                GameGrid(prefix: "search", games: results, model: model)
            }
        }
        .onAppear { fieldFocused = model.searchFieldFocused }
        .onChange(of: model.searchFieldFocused) { fieldFocused = $0 }
        .onChange(of: fieldFocused) { focused in
            if model.searchFieldFocused != focused { model.searchFieldFocused = focused }
        }
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
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
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
