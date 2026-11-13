//
//  StarlightHomeTab.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

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
