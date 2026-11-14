//
//  StarlightGameDetail.swift
//  Starlight
//

import SwiftUI
import AVKit
import UIKit
import Network
import GameController
import Security

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

@available(iOS 16.0, *)
struct GameDetailView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared
    @ObservedObject private var focus = GameFocus.shared
    @ObservedObject private var steamArt = SteamOnlyArtwork.shared
    @ObservedObject private var store = SteamStore.shared
    let game: GameItem
    @State private var page: GameDetailPage?
    @State private var media: GameMediaViewer?

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
                                // Only Edit Artwork applies to a game that isn't on the PC
                                Menu {
                                    GameMenuItems(game: game, model: model)
                                } label: {
                                    Image(systemName: device.controllerConnected ? PadGlyph.options : "ellipsis")
                                        .font(.system(size: device.controllerConnected ? 18 : 16, weight: .semibold))
                                        .frame(width: 22, height: 26)
                                }
                                .secondaryGlassButton()
                                .accessibilityLabel("Game options")
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
                            SteamPlaytimeRow(appid: appid)
                                .padding(.top, 4)
                            steamSections(appid: appid, mediaHeight: min(170, max(110, geo.size.height * 0.26)))
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
                    } else if focused != "media-viewer" {
                        proxy.scrollTo(focused, anchor: .center)
                    }
                }
            }
            }
        }
        .overlay {
            if let media = media {
                GameMediaOverlay(viewer: media) { withAnimation { self.media = nil } }
            }
        }
        .toolbar(media == nil ? .automatic : .hidden, for: .navigationBar)
        .toolbar(media == nil ? .automatic : .hidden, for: .tabBar)
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(get: { page != nil }, set: { if !$0 { page = nil } })) {
            pageView
        }
        .onAppear {
            GameFocus.shared.push("detail")
            // Connect Early: make sure the PC is awake before Play
            if game.isInstalled { model.onHostAction?("connectEarly", game.host) }
        }
        .onDisappear { GameFocus.shared.pop("detail") }
        .task(id: game.steamAppId) {
            if let appid = game.steamAppId { await store.load(appid) }
        }
    }

    /// Steam store order: description, trailers & screenshots, patches, news, then achievements
    @ViewBuilder
    private func steamSections(appid: Int, mediaHeight: CGFloat) -> some View {
        if let info = store.info[appid] {
            GameAboutSection(info: info) { page = .about }
                .padding(.top, 10)
            if !info.featuredMovies.isEmpty || !info.screenshots.isEmpty {
                GameMediaRow(info: info, height: mediaHeight) { viewer in withAnimation { media = viewer } }
                    .padding(.top, 6)
            }
        }
        if let news = store.news[appid] {
            if !news.patches.isEmpty {
                GameNewsSection(title: "Patches", idPrefix: "patch", items: news.patches,
                                openItem: { page = .article($0.id) }, openAll: { page = .patches })
                    .padding(.top, 6)
            }
            if !news.news.isEmpty {
                GameNewsSection(title: "News", idPrefix: "news", items: news.news,
                                openItem: { page = .article($0.id) }, openAll: { page = .news })
                    .padding(.top, 6)
            }
        }
        GameAchievementsSummary(appid: appid) { page = .achievements }
            .padding(.top, 6)
    }

    @ViewBuilder
    private var pageView: some View {
        if let appid = game.steamAppId, let page = page {
            switch page {
            case .about:
                if let info = store.info[appid] { GameAboutPage(gameName: game.name, info: info) }
            case .patches:
                GameNewsListPage(title: "Patches", items: store.news[appid]?.patches ?? [])
            case .news:
                GameNewsListPage(title: "News", items: store.news[appid]?.news ?? [])
            case .article(let id):
                if let item = store.news[appid]?.items.first(where: { $0.id == id }) { NewsArticlePage(item: item) }
            case .achievements:
                GameAchievementsPage(appid: appid)
            }
        }
    }

    private func hero(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay(
                    ArtworkImage(path: game.artPath("hero") ?? game.artPath("grid"), fallbackText: "",
                                 remoteURL: game.isInstalled ? nil : game.steamAppId.flatMap { SteamManager.heroURL($0) })
                )
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let logo = ArtworkCache.shared.image(game.artPath("logo")) {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 380, maxHeight: 110, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                        .accessibilityLabel(game.name)
                } else if !game.isInstalled, let appid = game.steamAppId, let url = SteamManager.logoURL(appid) {
                    // While the Steam-only game's artwork downloads
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text(game.name).font(.system(size: 36, weight: .heavy)).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 380, maxHeight: 110, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
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
    /// Steam-only games download their artwork as they appear
    @ObservedObject private var steamArt = SteamOnlyArtwork.shared

    var body: some View {
        let width = portrait ? height * 2 / 3 : height * 16 / 9
        ZStack(alignment: .bottomLeading) {
            // Portrait cards: the portrait cover. Landscape cards: the same background as the Home screen, plus the logo
            ArtworkImage(path: portrait ? game.artPath("grid") : (game.artPath("hero") ?? game.artPath("grid")), fallbackText: game.name,
                         remoteURL: game.isInstalled ? nil : game.steamAppId.flatMap { portrait ? SteamManager.coverURL($0) : SteamManager.heroURL($0) })
                .frame(width: width, height: height)
                .clipped()
                .onAppear { steamArt.ensure(game) }

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


// MARK: - Game page: Steam store sections (description, media, patches, news, achievements)

/// Pages pushed from the game page
enum GameDetailPage: Hashable {
    case about
    case patches
    case news
    case article(String)
    case achievements
}

/// Full-screen trailer or screenshots, drawn over the game page
enum GameMediaViewer: Equatable {
    case movie(SteamMovie)
    case screenshots([SteamScreenshot], Int)
}

private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 20, weight: .bold))
        if let count = count, count > 0 {
            Text("\(count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
        Spacer()
    }
}

/// Playtime from Steam (kept near the top of the page)
struct SteamPlaytimeRow: View {
    let appid: Int
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        if let owned = steam.owned(appid) {
            HStack(spacing: 22) {
                stat(SteamManager.formatPlaytime(owned.playtimeForever), "Played")
                if let recent = steam.recent(appid), recent.playtimeTwoWeeks > 0 {
                    stat(SteamManager.formatPlaytime(recent.playtimeTwoWeeks), "Last 2 weeks")
                }
                if let last = owned.lastPlayed {
                    stat(last.formatted(date: .abbreviated, time: .omitted), "Last played")
                }
                if let stats = steam.achievements[appid], !stats.achievements.isEmpty {
                    stat("\(stats.unlockedCount)/\(stats.achievements.count)", "Achievements")
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// Short description, with More for the full store text
struct GameAboutSection: View {
    let info: SteamStoreInfo
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")
            if !info.shortDescription.isEmpty {
                Text(info.shortDescription)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 720, alignment: .leading)
            }
            HStack(spacing: 14) {
                if !info.genres.isEmpty {
                    Text(info.genres.prefix(3).joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Button(action: open) {
                    Text("More").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(starlightGold)
                .gameFocus("detail-about", scope: "detail", corner: 8, action: open)
            }
        }
    }
}

/// Trailers first, then screenshots, in one row (like the Steam store)
struct GameMediaRow: View {
    let info: SteamStoreInfo
    let height: CGFloat
    let show: (GameMediaViewer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Trailers & Screenshots")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(info.featuredMovies) { movie in
                        tile(url: movie.thumb, isMovie: true, id: "media-movie-\(movie.id)") { show(.movie(movie)) }
                    }
                    ForEach(Array(info.screenshots.enumerated()), id: \.offset) { index, shot in
                        tile(url: shot.thumb, isMovie: false, id: "media-shot-\(index)") {
                            show(.screenshots(info.screenshots, index))
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    private func tile(url: String, isMovie: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                AsyncImage(url: URL(string: url)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                if isMovie {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .glassCapsule()
                }
            }
            .frame(width: height * 16 / 9, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMovie ? "Play trailer" : "Screenshot")
        .gameFocus(id, scope: "detail", corner: 12, action: action)
    }
}

/// Patches or News: the latest few, with See All
struct GameNewsSection: View {
    let title: String
    let idPrefix: String
    let items: [SteamNewsItem]
    let openItem: (SteamNewsItem) -> Void
    let openAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, count: items.count)
            ForEach(items.prefix(3)) { item in
                NewsRow(item: item)
                    .onTapGesture { openItem(item) }
                    .gameFocus("\(idPrefix)-\(item.id)", scope: "detail", corner: 14) { openItem(item) }
            }
            if items.count > 3 {
                Button(action: openAll) {
                    Text("See All \(title)").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(starlightGold)
                .padding(.top, 2)
                .gameFocus("\(idPrefix)-all", scope: "detail", corner: 8, action: openAll)
            }
        }
    }
}

struct NewsRow: View {
    let item: SteamNewsItem

    var body: some View {
        HStack(spacing: 12) {
            if let url = SteamText.imageURLs(inBBCode: item.contents).first {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 720)
        .contentShape(Rectangle())
        .modifier(PanelGlass(corner: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Achievements, summarised: progress and the three most relevant, with See All
struct GameAchievementsSummary: View {
    let appid: Int
    let openAll: () -> Void
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        Group {
            if let stats = steam.achievements[appid], !stats.achievements.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Achievements").font(.system(size: 20, weight: .bold))
                        Spacer()
                        Text("\(stats.unlockedCount) of \(stats.achievements.count)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 560)
                    ProgressView(value: Double(stats.unlockedCount), total: Double(max(stats.achievements.count, 1)))
                        .tint(starlightGold)
                        .frame(maxWidth: 560)
                    ForEach(GameAchievementsSummary.sorted(stats.achievements).prefix(3)) { achievement in
                        AchievementRow(achievement: achievement)
                    }
                    Button(action: openAll) {
                        Text("See All Achievements").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(starlightGold)
                    .gameFocus("ach-all", scope: "detail", corner: 8, action: openAll)
                }
            } else if steam.achievements[appid] == nil && steam.isConfigured {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading achievements…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: appid) { await steam.loadAchievements(appid) }
    }

    /// Unlocked first (most recent first), then locked from most to least common
    static func sorted(_ list: [SteamAchievement]) -> [SteamAchievement] {
        list.sorted { a, b in
            if a.achieved != b.achieved { return a.achieved }
            if a.achieved { return (a.unlocked ?? .distantPast) > (b.unlocked ?? .distantPast) }
            return (a.percent ?? 0) > (b.percent ?? 0)
        }
    }
}

// MARK: Pushed pages

/// Shared look for the pages pushed from the game page (○ goes back)
private struct DetailSubpage<Content: View>: View {
    let title: String
    let scope: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(FocusScrollFollower(proxy: proxy))
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .settingsScreen(scope, dismiss: dismiss)
    }
}

struct GameAboutPage: View {
    let gameName: String
    let info: SteamStoreInfo

    var body: some View {
        DetailSubpage(title: gameName, scope: "detail-about") {
            Text(SteamText.attributed(fromHTML: info.aboutHTML.isEmpty ? info.shortDescription : info.aboutHTML))
                .font(.system(size: 15))
                .tint(starlightGold)
                .frame(maxWidth: 760, alignment: .leading)
                // An invisible stop so ○ and the D-pad scroll work on this page
                .gameFocus("about-text", scope: "detail-about", corner: 4) {}
            VStack(alignment: .leading, spacing: 6) {
                fact("Developer", info.developers.joined(separator: ", "))
                fact("Publisher", info.publishers.joined(separator: ", "))
                fact("Genre", info.genres.joined(separator: ", "))
                fact("Released", info.releaseDate)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(value).font(.system(size: 14))
            }
        }
    }
}

@available(iOS 16.0, *)
struct GameNewsListPage: View {
    let title: String
    let items: [SteamNewsItem]
    @State private var article: SteamNewsItem?

    var body: some View {
        DetailSubpage(title: title, scope: "detail-list") {
            ForEach(items) { item in
                NewsRow(item: item)
                    .onTapGesture { article = item }
                    .gameFocus("list-\(item.id)", scope: "detail-list", corner: 14) { article = item }
            }
        }
        .navigationDestination(isPresented: Binding(get: { article != nil }, set: { if !$0 { article = nil } })) {
            if let item = article { NewsArticlePage(item: item) }
        }
    }
}

struct NewsArticlePage: View {
    let item: SteamNewsItem

    var body: some View {
        DetailSubpage(title: item.isPatch ? "Patch Notes" : "News", scope: "detail-article") {
            if let url = SteamText.imageURLs(inBBCode: item.contents).first {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.white.opacity(0.06).frame(height: 180)
                    }
                }
                .frame(maxWidth: 760)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text(item.title)
                .font(.system(size: 24, weight: .bold))
                .frame(maxWidth: 760, alignment: .leading)
            Text(item.date.formatted(date: .long, time: .omitted) + (item.author.isEmpty ? "" : " · \(item.author)"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(SteamText.attributed(fromBBCode: item.contents))
                .font(.system(size: 15))
                .tint(starlightGold)
                .frame(maxWidth: 760, alignment: .leading)
                .gameFocus("article-text", scope: "detail-article", corner: 4) {}
            if let url = URL(string: item.url), !item.url.isEmpty {
                Link("Open on Steam", destination: url)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(starlightGold)
                    .padding(.top, 8)
                    .gameFocus("article-open", scope: "detail-article", corner: 8) { UIApplication.shared.open(url) }
            }
        }
    }
}

struct GameAchievementsPage: View {
    let appid: Int
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        DetailSubpage(title: "Achievements", scope: "detail-achievements") {
            if let stats = steam.achievements[appid] {
                Text("\(stats.unlockedCount) of \(stats.achievements.count) unlocked")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(stats.unlockedCount), total: Double(max(stats.achievements.count, 1)))
                    .tint(starlightGold)
                    .frame(maxWidth: 560)
                ForEach(GameAchievementsSummary.sorted(stats.achievements)) { achievement in
                    AchievementRow(achievement: achievement)
                        .gameFocus("ach-\(achievement.id)", scope: "detail-achievements", corner: 14) {}
                }
            }
        }
    }
}

// MARK: Full-screen media

/// Trailer (system player, starts when opened) or screenshots (swipe, ← / → on the controller)
struct GameMediaOverlay: View {
    let viewer: GameMediaViewer
    let close: () -> Void
    @State private var index = 0
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            switch viewer {
            case .movie:
                if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                }
            case .screenshots(let shots, _):
                TabView(selection: $index) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { i, shot in
                        AsyncImage(url: URL(string: shot.full)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                ProgressView()
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .ignoresSafeArea()
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .secondaryGlassButton()
            .padding(20)
            .accessibilityLabel("Close")
        }
        // One invisible controller stop for the whole viewer: ✕ play/pause, ← / → previous/next
        // screenshot (or ∓10 s on a trailer), ○ close
        .background(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .modifier(GameFocusModifier(id: "media-viewer", scope: "media", corner: 0, action: toggle, scales: false, adjust: step))
                .opacity(0)
        }
        .onAppear {
            if case .screenshots(_, let start) = viewer { index = start }
            if case .movie(let movie) = viewer, let url = URL(string: movie.hls) {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            GameFocus.shared.push("media")
            GameFocus.shared.focus("media-viewer")
            GameFocus.shared.setBack("media") { close() }
        }
        .onDisappear {
            player?.pause()
            player = nil
            GameFocus.shared.setBack("media", nil)
            GameFocus.shared.pop("media")
        }
        .transition(.opacity)
    }

    private func toggle() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    private func step(_ delta: Int) {
        if case .screenshots(let shots, _) = viewer {
            withAnimation { index = min(max(index + delta, 0), shots.count - 1) }
        } else if let player = player {
            // ← / → on a trailer: back / forward 10 s
            let target = player.currentTime().seconds + Double(delta * 10)
            player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
        }
    }
}
