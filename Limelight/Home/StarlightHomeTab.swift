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
        // iPad sidebar: the list starts at the sidebar's edge (the art continues under the glass by itself)
        SidebarAware { sidebar in
        GeometryReader { geo in
            let compact = geo.size.height < 440
            let leading = (sidebar ? 0 : geo.safeAreaInsets.leading) + 24
            let trailing = geo.safeAreaInsets.trailing + 24
            let screenHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            // iPhone in landscape: the carousel fills the screen. iPhone in portrait and iPad: Apple TV app proportion
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let phoneLandscape = !isPad && geo.size.width > geo.size.height
            // iPad upright: no taller than the screen is wide, so the rows below still show
            let carouselHeight = phoneLandscape ? screenHeight
                : (isPad ? min(screenHeight * 0.78, geo.size.width) : screenHeight * 0.78).rounded()
            let recent = Array(model.continueGames.prefix(5))
            Group {
                if model.featured != nil {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: compact ? 14 : 22) {
                                if recent.isEmpty {
                                    Color.clear.frame(height: geo.safeAreaInsets.top)
                                } else {
                                    HomeCarousel(games: recent, model: model, height: carouselHeight,
                                                 bottomInset: phoneLandscape ? geo.safeAreaInsets.bottom : 0, compact: compact,
                                                 leadingAligned: isPad, leadingInset: leading + 16)
                                        .id("section-featured")
                                }

                                GameRow(id: "all", title: "Ready to Play", games: model.libraryGames, model: model,
                                        compact: compact, leadingInset: leading, trailingInset: trailing, zoom: zoom)
                                    .id("section-all")
                            }
                            .padding(.bottom, 40)
                        }
                        // Under the navigation bar (the carousel starts at the top of the screen) and edge to edge
                        // (with the sidebar: from its edge)
                        .ignoresSafeArea(.container, edges: sidebar ? [.trailing, .top] : [.horizontal, .top])
                        .modifier(HomeScrollState(progress: $titleProgress))
                        .modifier(TabBarAutoHideScroll())
                        .modifier(TopEdgeEffect(hidden: titleProgress < 0.5))
                        .onChange(of: focus.focusedID) { id in
                            scroll(to: id, proxy: proxy)
                        }
                    }
                } else {
                    EmptyStateView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
        }
        }
        .modifier(HomeTitle(visible: model.featured != nil, progress: titleProgress))
        .modifier(GameDetailDestination(model: model, tab: .home, zoom: zoom))
    }

    private func scroll(to id: String?, proxy: ScrollViewProxy) {
        guard let id = id else { return }
        let section: String?
        if id.hasPrefix("card-all-") {
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
}

/// "Play Now": iPad after the tab bar goes; iPhone fading in with the scroll (left when upright, centred in landscape)
struct HomeTitle: ViewModifier {
    let visible: Bool
    let progress: Double

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    PadTabTitle(title: "Play Now")
                        .opacity(visible ? 1 : 0)
                }
            }
        } else {
            content.modifier(PhoneTitle(title: "Play Now", opacity: visible ? progress : 0))
        }
    }
}

/// The navigation bar's blur over the carousel only once the list scrolls (iOS 26)
struct TopEdgeEffect: ViewModifier {
    var hidden: Bool = false

    func body(content: Content) -> some View {
        // iPad with the sidebar: no glass bar on top at all
        SidebarAware { sidebar in
            if #available(iOS 26.0, *) {
                content.scrollEdgeEffectHidden(hidden || sidebar, for: .top)
            } else {
                content
            }
        }
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
                .font(.system(size: 20, weight: .bold))
                .padding(.leading, leadingInset)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: every card needs a frame for controller navigation
                    HStack(spacing: 14) {
                        ForEach(games) { game in
                            ShelfCard(game: game,
                                      selected: game.id == model.featured?.id && model.featuredRow == id,
                                      height: compact ? 140 : 170,
                                      model: model)
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
