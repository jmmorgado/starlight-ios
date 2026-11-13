//
//  StarlightGameDetail.swift
//  Starlight
//

import SwiftUI
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
