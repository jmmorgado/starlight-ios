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
