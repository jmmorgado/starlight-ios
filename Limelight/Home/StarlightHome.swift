//
//  StarlightHome.swift
//  Starlight
//
//  The Starlight home screen: a SwiftUI layer on top of MainFrameViewController.
//  MainFrameViewController keeps doing the Moonlight work (discovery, pairing,
//  app lists, streaming) and pushes plain dictionaries here; taps go back
//  through the closures below.
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
        return controller
    }()

    @objc var viewController: UIViewController { hosting }

    /// (hostUUID)
    @objc var onSelectHost: ((String) -> Void)? {
        didSet { model.onSelectHost = onSelectHost }
    }
    /// (hostUUID, appId)
    @objc var onLaunchApp: ((String, String) -> Void)? {
        didSet { model.onLaunchApp = onLaunchApp }
    }
    /// (action, hostUUID, appId): "pin", "copyLink", "saveIcon", "more"
    @objc var onAppAction: ((String, String, String) -> Void)? {
        didSet { model.onAppAction = onAppAction }
    }
    /// (command): "addHost", "refreshHost", "hostOptions", "streamSettings", "artwork", "classicLayout"
    @objc var onCommand: ((String) -> Void)? {
        didSet { model.onCommand = onCommand }
    }

    @objc(updateWithHosts:selectedHost:apps:)
    func update(hosts: [[String: Any]], selectedHost: String?, apps: [[String: Any]]) {
        let hostItems = hosts.compactMap(HostItem.init)
        let gameItems = apps.compactMap(GameItem.init)
        if model.hosts != hostItems { model.hosts = hostItems }
        if model.selectedHost != selectedHost { model.selectedHost = selectedHost }
        if model.games != gameItems {
            model.games = gameItems
            ArtworkCache.shared.removeAll()
        }
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

    init?(_ dict: [String: Any]) {
        guard let uuid = dict["uuid"] as? String else { return nil }
        id = uuid
        name = dict["name"] as? String ?? "PC"
        online = dict["online"] as? Bool ?? false
        paired = dict["paired"] as? Bool ?? false
    }
}

struct GameItem: Identifiable, Equatable {
    let id: String
    let host: String
    let app: String
    let name: String
    let hostName: String
    let running: Bool
    let pinned: Bool
    let gridPath: String?
    let heroPath: String?
    let logoPath: String?
    let lastPlayed: Date?

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
        pinned = dict["pinned"] as? Bool ?? false
        gridPath = GameItem.nonEmpty(dict["gridPath"])
        heroPath = GameItem.nonEmpty(dict["heroPath"])
        logoPath = GameItem.nonEmpty(dict["logoPath"])
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

    var onSelectHost: ((String) -> Void)?
    var onLaunchApp: ((String, String) -> Void)?
    var onAppAction: ((String, String, String) -> Void)?
    var onCommand: ((String) -> Void)?

    var currentHost: HostItem? { hosts.first { $0.id == selectedHost } }

    /// Running game first, then most recently played, then alphabetical
    var continueGames: [GameItem] {
        games.sorted { a, b in
            if a.running != b.running { return a.running }
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    var alphabeticalGames: [GameItem] {
        games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var featured: GameItem? {
        if let id = featuredId, let game = games.first(where: { $0.id == id }) { return game }
        return continueGames.first
    }

    func launch(_ game: GameItem) { onLaunchApp?(game.host, game.app) }
    func action(_ name: String, _ game: GameItem) { onAppAction?(name, game.host, game.app) }
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
    func glassRounded(_ radius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
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
    }
}

// MARK: - Shared pieces

struct HostMenu: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        Menu {
            if !model.hosts.isEmpty {
                Section("PCs") {
                    ForEach(model.hosts) { host in
                        Button {
                            model.onSelectHost?(host.id)
                        } label: {
                            Label(host.name + (host.paired ? "" : " (not paired)"),
                                  systemImage: host.id == model.selectedHost ? "checkmark" : (host.online ? "desktopcomputer" : "moon.zzz"))
                        }
                    }
                }
            }
            Section {
                if model.currentHost != nil {
                    Button { model.command("refreshHost") } label: { Label("Refresh Games", systemImage: "arrow.clockwise") }
                    Button { model.command("hostOptions") } label: { Label("PC Options…", systemImage: "ellipsis.circle") }
                }
                Button { model.command("addHost") } label: { Label("Add PC…", systemImage: "plus") }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
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
        if !host.paired { return "Not paired" }
        return host.online ? "Online" : "Offline · last known games"
    }
}

struct ArtworkImage: View {
    let path: String?
    let fallbackText: String
    var contentMode: ContentMode = .fill

    var body: some View {
        if let image = ArtworkCache.shared.image(path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
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

struct GameContextMenu: View {
    let game: GameItem
    @ObservedObject var model: HomeModel

    var body: some View {
        Button { model.launch(game) } label: {
            Label(game.running ? "Resume" : "Play", systemImage: "play.fill")
        }
        Button { model.action("pin", game) } label: {
            Label(game.pinned ? "Unpin from App Icon" : "Pin to App Icon", systemImage: game.pinned ? "pin.slash" : "pin")
        }
        Button { model.action("copyLink", game) } label: {
            Label("Copy Shortcut Link", systemImage: "link")
        }
        Button { model.action("saveIcon", game) } label: {
            Label("Save Icon to Photos", systemImage: "photo")
        }
        Button { model.action("more", game) } label: {
            Label("More Options…", systemImage: "ellipsis.circle")
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
            } else if model.currentHost != nil {
                Button { model.command("refreshHost") } label: {
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
                            HStack {
                                HostMenu(model: model)
                                Spacer()
                                Button { model.command("artwork") } label: {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 22, height: 22)
                                }
                                .secondaryGlassButton()
                                .accessibilityLabel("Game artwork")
                            }

                            FeaturedSection(game: featured, model: model, compact: compact)

                            GameRow(title: "Continue Playing", games: model.continueGames, model: model, compact: compact)

                            if !compact {
                                GameRow(title: "All Games", games: model.alphabeticalGames, model: model, compact: compact, portrait: true)
                            }
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
                Image(uiImage: hero)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
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
                    Label("Running on PC", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassCapsule()
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

                Button { model.action("pin", game) } label: {
                    Image(systemName: game.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .secondaryGlassButton()
                .accessibilityLabel(game.pinned ? "Unpin from app icon" : "Pin to app icon")

                Menu {
                    GameContextMenu(game: game, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .secondaryGlassButton()
                .accessibilityLabel("More options")
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
                                 selected: game.id == model.featured?.id,
                                 portrait: portrait,
                                 height: portrait ? 180 : (compact ? 84 : 110))
                            .onTapGesture {
                                if game.id == model.featured?.id {
                                    model.launch(game)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.25)) { model.featuredId = game.id }
                                }
                            }
                            .contextMenu { GameContextMenu(game: game, model: model) }
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

            if game.running {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(0.4), radius: selected ? 10 : 5, y: 4)
        .scaleEffect(selected ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name + (game.running ? ", running" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Library tab

struct LibraryTab: View {
    @ObservedObject var model: HomeModel
    @State private var search = ""

    private var filtered: [GameItem] {
        let all = model.alphabeticalGames
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
                                .contextMenu { GameContextMenu(game: game, model: model) }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle(model.currentHost?.name ?? "Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HostMenu(model: model)
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
                    Button { model.command("streamSettings") } label: {
                        Label("Stream Settings", systemImage: "slider.horizontal.3")
                    }
                }
                Section("PCs") {
                    Button { model.command("addHost") } label: {
                        Label("Add PC…", systemImage: "plus")
                    }
                    if model.currentHost != nil {
                        Button { model.command("hostOptions") } label: {
                            Label("Options for \(model.currentHost?.name ?? "PC")…", systemImage: "desktopcomputer")
                        }
                    }
                }
                Section("Appearance") {
                    Button { model.command("artwork") } label: {
                        Label("Game Artwork (SteamGridDB)", systemImage: "photo.on.rectangle.angled")
                    }
                    Button { model.command("classicLayout") } label: {
                        Label("Use Classic Moonlight Layout", systemImage: "rectangle.grid.1x2")
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
