//
//  StarlightLibrary.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

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
                    header(count: shown.count)
                }
            }
        }
        .modifier(GameDetailDestination(model: model, tab: .library, zoom: zoom))
    }

    /// One line when there's room; filter above sort and count when upright on iPhone
    @ViewBuilder
    private func header(count: Int) -> some View {
        let stacked = VStack(alignment: .leading, spacing: 10) {
            filterPicker
            HStack {
                sortMenu
                Spacer(minLength: 0)
                gameCount(count)
            }
        }
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterPicker.frame(width: 360)
                    sortMenu
                    Spacer(minLength: 0)
                    gameCount(count)
                }
                stacked
            }
        } else {
            stacked
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(GameCollection.Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(GameCollection.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .semibold))
        }
        .secondaryGlassButton()
    }

    private func gameCount(_ count: Int) -> some View {
        Text("\(count) games")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize()
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

    /// Posters fill the width: as many columns as fit at the minimum size (Apple TV app size on iPad),
    /// recomputed when the device turns
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var minCardWidth: CGFloat { isPad ? 150 : 104 }
    private var spacing: CGFloat { isPad ? 22 : 14 }

    var body: some View {
        GeometryReader { geo in
            let available = max(200, geo.size.width - 48)
            let columns = max(2, Int((available + spacing) / (minCardWidth + spacing)))
            let cardWidth = ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            let _ = focus.registerGrid(prefix, ids: games.map { "\(prefix)-\($0.id)" }, columns: columns)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        header()
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: columns),
                                  alignment: .leading, spacing: spacing) {
                            ForEach(games) { game in
                                let focusID = "\(prefix)-\(game.id)"
                                PosterCard(game: game, height: (cardWidth * 1.5).rounded(), showsReadyBadge: showsReadyBadge)
                                    .modifier(ZoomSource(id: focusID, zoom: zoom))
                                    .gameFocus(focusID, corner: 14) { model.openDetail(game, source: focusID) }
                                    .frame(width: cardWidth)
                                    .onTapGesture { model.openDetail(game, source: focusID) }
                                    .contextMenu {
                                        GameMenuItems(game: game, model: model)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(TabBarAutoHideScroll())
                .modifier(TopEdgeEffect())
                .onChange(of: focus.focusedID) { focused in
                    guard let focused = focused, focused.hasPrefix("\(prefix)-") else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(focused, anchor: .center)
                    }
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
            } else if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                // Before typing: recent searches and a couple of rows, not the whole collection again
                SearchSuggestions(model: model, zoom: zoom)
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

/// The last searches that led somewhere (submitted, or a result opened)
enum RecentSearches {
    private static let key = "StarlightRecentSearches"
    static let limit = 8

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Search before typing: recent searches, then Recently Played and Ready to Play
struct SearchSuggestions: View {
    @ObservedObject var model: HomeModel
    var zoom: Namespace.ID? = nil
    @State private var recents = RecentSearches.load()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 440
            let leading = geo.safeAreaInsets.leading + 24
            let trailing = geo.safeAreaInsets.trailing + 24
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if !recents.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Recent Searches").font(.system(size: 20, weight: .bold))
                                Spacer()
                                Button("Clear") {
                                    RecentSearches.clear()
                                    withAnimation { recents = [] }
                                }
                                .font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.bottom, 6)
                            ForEach(recents, id: \.self) { query in
                                Button {
                                    model.searchQuery = query
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(.secondary)
                                        Text(query)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .font(.system(size: 16))
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .gameFocus("search-recent-\(query)", corner: 8) { model.searchQuery = query }
                                Divider()
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.leading, leading)
                        .padding(.trailing, trailing)
                    }

                    let recent = Array(model.continueGames.prefix(10))
                    if !recent.isEmpty {
                        GameRow(id: "search-played", title: "Recently Played", games: recent, model: model,
                                compact: compact, leadingInset: leading, trailingInset: trailing, zoom: zoom)
                    }
                    GameRow(id: "search-ready", title: "Ready to Play", games: model.libraryGames, model: model,
                            compact: compact, leadingInset: leading, trailingInset: trailing, zoom: zoom)
                }
                .padding(.top, 8)
                .padding(.bottom, 90)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .modifier(TabBarAutoHideScroll())
            .modifier(TopEdgeEffect())
        }
        .onAppear { recents = RecentSearches.load() }
    }
}
