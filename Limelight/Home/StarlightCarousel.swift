//
//  StarlightCarousel.swift
//  Starlight
//

import SwiftUI
import UIKit
import AVFoundation
import Combine
import Network

// MARK: - Trailer autoplay state (shared by the carousel and the mute button)

final class HomeTrailerState: ObservableObject {
    static let shared = HomeTrailerState()

    /// Settings › Home › Autoplay Trailers: "wifi" (default), "always", "off"
    static let autoplayKey = "StarlightTrailerAutoplay"

    @Published var muted = true
    /// A trailer is playing in the carousel (shows the mute button)
    @Published var playing = false
    /// The Starlight screens are on top (false during a stream)
    @Published var screenActive = true
    /// The app is in the foreground (scenePhase isn't reliable under UIKit's life cycle)
    @Published private(set) var appActive = true
    @Published private(set) var expensiveNetwork = false
    private let monitor = NWPathMonitor()

    /// One shared clock for the carousel (a publisher made in the view would restart on every update)
    static let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.expensiveNetwork = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false
        }
    }

    var autoplayAllowed: Bool {
        switch UserDefaults.standard.string(forKey: Self.autoplayKey) ?? "wifi" {
        case "always": return true
        case "off": return false
        default: return !expensiveNetwork
        }
    }

    /// Muted trailers mix with other audio; with sound they take over like any video
    func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if muted {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback)
        }
    }
}

/// The carousel's slide, clock and trailer (one carousel: Home)
final class CarouselPlayback: ObservableObject {
    static let shared = CarouselPlayback()
    @Published var index = 0
    /// Seconds on the current game (art, then trailer)
    @Published var elapsed: Double = 0
    @Published var player: AVPlayer?
    @Published var videoVisible = false
    var endObserver: NSObjectProtocol?
    /// The game whose trailer is loaded
    var playingGameId: String?
    /// Carousel views on screen (a rebuild briefly shows two, or none)
    var appearances = 0
    /// The game whose logo, stats and buttons show: it follows `index` once the art has settled
    @Published var infoIndex = 0
    @Published var infoOpacity: Double = 1
    /// +1: the next game comes in from the right; -1: from the left
    @Published var direction: CGFloat = 1
    /// Bumped by each change, so the steps of an overtaken one are dropped
    var transitionToken = 0
    /// The game coming in while changing (under the finger, or animated), and how far it has come in (0…1)
    @Published var neighbor: Int?
    @Published var progress: CGFloat = 0
}

/// Mute button for the carousel trailer (navigation bar, next to the PC button)
struct TrailerMuteButton: View {
    @ObservedObject private var trailer = HomeTrailerState.shared

    var body: some View {
        if trailer.playing {
            Button {
                trailer.muted.toggle()
            } label: {
                Image(systemName: trailer.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.white)
            }
            .tint(.white)
            .accessibilityLabel(trailer.muted ? "Unmute trailer" : "Mute trailer")
        }
    }
}

// MARK: - Home carousel (last games played, Apple TV style)

/// The last games played, one at a time over their artwork. After 5 s the game's Steam trailer
/// plays (muted) over the art; when it ends, or after 8 s for games without one, the next game comes in.
struct HomeCarousel: View {
    let games: [GameItem]
    @ObservedObject var model: HomeModel
    let height: CGFloat
    /// Space to keep clear at the bottom (tab bar) when the carousel fills the screen
    let bottomInset: CGFloat
    let compact: Bool
    /// iPad: logo, text and buttons on the left (the dots stay centred), like the Apple TV app on iPad
    var leadingAligned = false
    /// From the slide's leading edge
    var leadingInset: CGFloat = 40
    /// iPad sidebar width (animated): the slides start at its edge, and a mirrored copy of the current one
    /// (art and trailer) sits under its glass, so the glass takes their colours like in the Apple TV app
    var sidebarInset: CGFloat = 0

    @ObservedObject private var trailer = HomeTrailerState.shared
    @ObservedObject private var store = SteamStore.shared
    @ObservedObject private var steam = SteamManager.shared

    /// Slide, timing and trailer live outside the view, so they survive the carousel being rebuilt
    /// (e.g. when the iPad switches between the tab bar and the sidebar)
    @ObservedObject private var playback = CarouselPlayback.shared

    private static let artDelay: Double = 5
    private static let artOnly: Double = 8

    private var current: GameItem? { games.indices.contains(playback.index) ? games[playback.index] : nil }

    private var active: Bool {
        trailer.screenActive && trailer.appActive && model.tab == .home && model.detail == nil
            && model.gameMenu == nil && !model.pcExpanded
    }

    private func trailerURL(_ game: GameItem) -> URL? {
        guard let appid = game.steamAppId, let info = store.info[appid] else { return nil }
        return (info.featuredMovies.first ?? info.movies.first).flatMap { URL(string: $0.hls) }
    }

    /// Whether this game will get a trailer (false once we know there's none, or autoplay is off)
    private func expectsTrailer(_ game: GameItem) -> Bool {
        guard trailer.autoplayAllowed, let appid = game.steamAppId else { return false }
        if let info = store.info[appid] { return !info.movies.isEmpty }
        return true
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - sidebarInset)
            ZStack(alignment: .topLeading) {
                // Under the iPad sidebar: the current game's art and trailer (the incoming one past halfway),
                // mirrored at the edge and blurred
                if sidebarInset > 0.5, let game = playback.progress > 0.5 ? (neighborGame ?? current) : current {
                    background(game, isCurrent: true, width: width)
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: sidebarInset, height: height, alignment: .trailing)
                        .clipped()
                        .blur(radius: 20, opaque: true)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                // Changing game, like the Apple TV app, following the finger (or animated): the current art slides
                // away and fades while the next one, already partly there underneath, comes in from the side and
                // fades in; the text and buttons fade out at the start and the next ones fade in at the end
                ZStack(alignment: .bottom) {
                    ZStack {
                        Color.black
                        ForEach(artLayers, id: \.game.id) { layer in
                            background(layer.game, isCurrent: !layer.incoming, width: width)
                                .offset(x: artOffset(incoming: layer.incoming, width: width))
                                .opacity(artOpacity(incoming: layer.incoming))
                                .zIndex(layer.incoming ? 1 : 0)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipped()
                    .allowsHitTesting(false)

                    if let game = infoGame {
                        foreground(game, isCurrent: playback.infoIndex == playback.index, width: width)
                            .opacity(playback.infoOpacity * (1 - min(1, Double(playback.progress) * 3)))
                    }

                    if games.count > 1 {
                        dots
                            .padding(.bottom, bottomInset + 14)
                    }
                }
                .frame(width: width, height: height)
                .modifier(CarouselSwipe(changed: { dx in swipeChanged(dx, width: width) },
                                        ended: { dx, velocity in swipeEnded(dx, velocity: velocity, width: width) }))
                .offset(x: sidebarInset)
            }
        }
        .frame(height: height)
        .onReceive(HomeTrailerState.ticker) { _ in step() }
        .onChange(of: playback.index) { _ in
            // The pager re-reporting the same page (it does on resize) isn't a new slide
            if let id = current?.id, id == playback.playingGameId { return }
            stopVideo()
            playback.elapsed = 0
            if let game = current { model.featuredId = game.id }
        }
        .onChange(of: active) { isActive in
            if isActive { playback.player?.play() } else { playback.player?.pause() }
        }
        .onChange(of: trailer.muted) { muted in
            trailer.applyAudioSession()
            playback.player?.isMuted = muted
        }
        .onChange(of: games.map(\.id)) { ids in
            if playback.index >= ids.count { playback.index = 0 }
            if playback.infoIndex >= ids.count { playback.infoIndex = playback.index }
        }
        .onAppear {
            playback.appearances += 1
            if games.indices.contains(playback.index) == false { playback.index = 0 }
            if games.indices.contains(playback.infoIndex) == false { playback.infoIndex = playback.index }
            if let game = current { model.featuredId = game.id }
            if active { playback.player?.play() }
        }
        .onDisappear {
            // Rebuilt views disappear and reappear at once: only stop if the carousel is really gone
            playback.appearances -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if playback.appearances <= 0 { stopVideo() }
            }
        }
        .task(id: current?.id) {
            guard let game = current else { return }
            if let appid = game.steamAppId {
                await store.load(appid)
                if steam.isConfigured { await steam.loadAchievements(appid) }
            }
        }
    }

    // MARK: Changing game

    private struct ArtLayer {
        let game: GameItem
        let incoming: Bool
    }

    private var neighborGame: GameItem? {
        guard let i = playback.neighbor, games.indices.contains(i) else { return nil }
        return games[i]
    }

    /// The current art, and the incoming one while changing
    private var artLayers: [ArtLayer] {
        var layers: [ArtLayer] = []
        if let game = current { layers.append(ArtLayer(game: game, incoming: false)) }
        if let game = neighborGame, game.id != current?.id { layers.append(ArtLayer(game: game, incoming: true)) }
        return layers
    }

    /// Outgoing: slides away with the finger (half its pace). Incoming: comes in from a third of the way over
    private func artOffset(incoming: Bool, width: CGFloat) -> CGFloat {
        guard neighborGame != nil else { return 0 }
        let p = playback.progress
        return incoming ? playback.direction * width * 0.3 * (1 - p) : -playback.direction * width * 0.5 * p
    }

    private func artOpacity(incoming: Bool) -> Double {
        guard neighborGame != nil else { return 1 }
        let p = Double(playback.progress)
        return incoming ? p : 1 - p
    }

    private var infoGame: GameItem? {
        games.indices.contains(playback.infoIndex) ? games[playback.infoIndex] : current
    }

    /// Animated change (trailer end, dots, controller): the same as a full swipe
    private func change(to target: Int, direction: CGFloat) {
        guard games.count > 1, games.indices.contains(target), target != playback.index else { return }
        playback.transitionToken += 1
        let token = playback.transitionToken
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            playback.direction = direction
            playback.neighbor = target
            playback.progress = 0
        }
        DispatchQueue.main.async {
            guard token == playback.transitionToken else { return }
            withAnimation(.easeInOut(duration: 0.9)) { playback.progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { commit(token) }
        }
    }

    /// The incoming game becomes the current one (they look the same at this point), then its text fades in
    private func commit(_ token: Int) {
        guard token == playback.transitionToken, let target = playback.neighbor else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            playback.index = target
            playback.neighbor = nil
            playback.progress = 0
            playback.infoIndex = target
            playback.infoOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.1)) { playback.infoOpacity = 1 }
    }

    /// The finger drives the change: left brings the next game, right the previous one (wrapping round)
    private func swipeChanged(_ dx: CGFloat, width: CGFloat) {
        guard games.count > 1, dx != 0 else { return }
        let direction: CGFloat = dx < 0 ? 1 : -1
        let target = (playback.index + (dx < 0 ? 1 : -1) + games.count) % games.count
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            // The finger takes over any change already under way
            playback.transitionToken += 1
            playback.neighbor = target
            playback.direction = direction
            // Across the whole slide, end to end
            playback.progress = min(1, abs(dx) / (width * 0.9))
        }
    }

    /// Past a quarter of the way (or flicked): it finishes; otherwise it goes back
    private func swipeEnded(_ dx: CGFloat, velocity: CGFloat, width: CGFloat) {
        guard playback.neighbor != nil else { return }
        let token = playback.transitionToken
        let along = playback.direction > 0 ? -(dx + velocity * 0.2) : (dx + velocity * 0.2)
        if along / width > 0.25 {
            let duration = max(0.2, 0.45 * Double(1 - playback.progress))
            withAnimation(.easeOut(duration: duration)) { playback.progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { commit(token) }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { playback.progress = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard token == playback.transitionToken, playback.progress == 0 else { return }
                playback.neighbor = nil
            }
        }
    }

    // MARK: Timing

    private func step() {
        guard active, playback.neighbor == nil, let game = current else { return }
        if let player = playback.player {
            // Trailer on screen: fade it in once frames are coming
            if !playback.videoVisible, player.timeControlStatus == .playing {
                withAnimation(.easeInOut(duration: 0.6)) { playback.videoVisible = true }
            }
            return
        }
        playback.elapsed += 0.1
        if playback.elapsed >= Self.artDelay, trailer.autoplayAllowed, let url = trailerURL(game) {
            startVideo(url)
        } else if !expectsTrailer(game), playback.elapsed >= Self.artOnly {
            advance()
        } else if playback.elapsed >= Self.artDelay + 6 {
            // Store details never arrived (offline): move on
            advance()
        }
    }

    private var progress: Double {
        guard let game = current else { return 0 }
        if let player = playback.player, let item = player.currentItem {
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return Self.artDelay / (Self.artDelay + 60) }
            return min(1, (Self.artDelay + player.currentTime().seconds) / (Self.artDelay + duration))
        }
        if expectsTrailer(game) {
            return min(1, playback.elapsed / (Self.artDelay + 60))
        }
        return min(1, playback.elapsed / Self.artOnly)
    }

    private func startVideo(_ url: URL) {
        trailer.applyAudioSession()
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 8_000_000
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = trailer.muted
        newPlayer.actionAtItemEnd = .pause
        playback.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            advance()
        }
        playback.player = newPlayer
        playback.playingGameId = current?.id
        trailer.playing = true
        if active { newPlayer.play() }
    }

    private func stopVideo() {
        playback.player?.pause()
        playback.player = nil
        playback.playingGameId = nil
        playback.videoVisible = false
        if let observer = playback.endObserver {
            NotificationCenter.default.removeObserver(observer)
            playback.endObserver = nil
        }
        trailer.playing = false
    }

    private func advance() {
        guard games.count > 1 else {
            // A single game: back to its art, and the trailer again later
            stopVideo()
            playback.elapsed = 0
            return
        }
        change(to: (playback.index + 1) % games.count, direction: 1)
    }

    /// One game on or back (wrapping round, like the Apple TV app)
    private func go(_ delta: Int) {
        guard !games.isEmpty else { return }
        change(to: (playback.index + delta + games.count) % games.count, direction: delta > 0 ? 1 : -1)
    }

    // MARK: Views

    /// Top: keeps the title and the toolbar readable. Bottom: a gentle fade into the rows below
    private var shade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height * 0.45)
        }
    }

    /// The game's art (zoomed to fill), its trailer when it's the current game, and the shade
    private func background(_ game: GameItem, isCurrent: Bool, width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
            ArtworkImage(path: game.artPath("hero") ?? game.artPath("grid"), fallbackText: "",
                         remoteURL: game.steamAppId.flatMap { SteamManager.heroURL($0) })
                .frame(width: width, height: height)
                .clipped()

            if isCurrent, let player = playback.player {
                TrailerLayerView(player: player)
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(playback.videoVisible ? 1 : 0)
                    .allowsHitTesting(false)
            }

            shade
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// Logo, stats and buttons; anywhere else opens the game's page
    private func foreground(_ game: GameItem, isCurrent: Bool, width: CGFloat) -> some View {
        info(game, isCurrent: isCurrent, width: width)
            .frame(maxWidth: leadingAligned ? min(max(width * 0.55, 380), 560) : .infinity, alignment: leadingAligned ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: leadingAligned ? .leading : .center)
            .padding(.bottom, bottomInset + (games.count > 1 ? 40 : 18))
            .padding(.leading, leadingAligned ? leadingInset : 24)
            .padding(.trailing, 24)
            .frame(width: width, height: height, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { model.openDetail(game, source: "featured-\(game.id)") }
    }

    private func info(_ game: GameItem, isCurrent: Bool, width: CGFloat) -> some View {
        // While the trailer plays, the name, hours and achievements fade out (keeping their space,
        // so the buttons stay put) and come back with the next game
        let trailerOn = isCurrent && playback.videoVisible
        let alignment: HorizontalAlignment = leadingAligned ? .leading : .center
        return VStack(alignment: alignment, spacing: compact ? 8 : 10) {
            VStack(alignment: alignment, spacing: compact ? 8 : 10) {
            if game.running {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Running on PC").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassCapsule()
            }

            if let logo = ArtworkCache.shared.image(game.artPath("logo")) {
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(width * 0.6, compact ? 320 : 440), maxHeight: compact ? 80 : 120,
                           alignment: leadingAligned ? .leading : .center)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .accessibilityLabel(game.name)
            } else {
                Text(game.name)
                    .font(.system(size: compact ? 30 : 38, weight: .heavy))
                    .multilineTextAlignment(leadingAligned ? .leading : .center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 10)
            }

            if let stats = statsLine(game) {
                Text(stats)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if let achievements = achievementsLine(game) {
                Text(achievements)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            }
            .opacity(trailerOn ? 0 : 1)
            .animation(.easeInOut(duration: 0.8), value: trailerOn)
            .accessibilityHidden(trailerOn)

            HStack(spacing: 12) {
                CarouselPlayButton(game: game, model: model, compact: compact)
                    .modifier(CarouselFocus(enabled: isCurrent, game: game, model: model, change: go))

                Menu {
                    GameMenuItems(game: game, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: compact ? 44 : 50, height: compact ? 44 : 50)
                        .contentShape(Circle())
                }
                .modifier(RoundGlass())
                .accessibilityLabel("Game options")
            }
            .padding(.top, 4)
        }
    }

    private func statsLine(_ game: GameItem) -> String? {
        var parts: [String] = []
        if game.running {
            parts.append("Playing now")
        } else if let last = model.effectiveLastPlayed(game) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Played " + formatter.localizedString(for: last, relativeTo: Date()))
        }
        if let appid = game.steamAppId, let owned = steam.owned(appid), owned.playtimeForever > 0 {
            parts.append(SteamManager.formatPlaytime(owned.playtimeForever) + " played")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func achievementsLine(_ game: GameItem) -> String? {
        guard let appid = game.steamAppId, let stats = steam.achievements[appid], !stats.achievements.isEmpty else { return nil }
        return "\(stats.unlockedCount) of \(stats.achievements.count) achievements"
    }

    /// One dot per game; the current one stretches and fills as its art and trailer play
    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(games.indices, id: \.self) { i in
                if i == playback.index {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 28, height: 8)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: max(8, 28 * progress), height: 8)
                        }
                } else {
                    Circle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { change(to: i, direction: i > playback.index ? 1 : -1) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: playback.index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Game \(playback.index + 1) of \(games.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: go(1)
            case .decrement: go(-1)
            @unknown default: break
            }
        }
    }
}

/// White capsule, like the main button in the Apple TV app
private struct CarouselPlayButton: View {
    let game: GameItem
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared
    let compact: Bool

    var body: some View {
        Button { model.launch(game) } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(game.running ? "Resume" : "Play")
                if device.controllerConnected {
                    Image(systemName: PadGlyph.play)
                        .opacity(0.55)
                }
            }
            .font(.system(size: compact ? 16 : 17, weight: .bold))
            .foregroundStyle(.black)
            .frame(minWidth: compact ? 170 : 210)
            .frame(height: compact ? 44 : 50)
            .padding(.horizontal, 18)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The controller's stop on the carousel: ✕ plays, ← / → change game
private struct CarouselFocus: ViewModifier {
    let enabled: Bool
    let game: GameItem
    @ObservedObject var model: HomeModel
    let change: (Int) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.modifier(GameFocusModifier(id: "featured-play", scope: "main", corner: 25,
                                               action: { model.launch(game) }, adjust: change))
        } else {
            content
        }
    }
}

/// Horizontal swipe between the carousel's games. iOS 18: a UIKit pan that only starts when the finger moves
/// sideways, so the list's vertical scrolling is untouched; earlier: a SwiftUI drag alongside the scroll
private struct CarouselSwipe: ViewModifier {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalPan(changed: changed, ended: ended))
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        changed(value.translation.width)
                    }
                    .onEnded { value in
                        ended(value.translation.width,
                              (value.predictedEndTranslation.width - value.translation.width) / 0.2)
                    }
            )
        }
    }
}

@available(iOS 18.0, *)
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed:
            changed(dx)
        case .ended, .cancelled:
            ended(dx, pan.velocity(in: pan.view).x)
        default:
            break
        }
    }
}

/// iPad hero height (Home carousel, game page): 16:9 of the width beside the sidebar, like the Apple TV app, so the
/// whole picture scales when the sidebar narrows it. Upright: no taller than that width, nor 78% of the screen
enum HeroLayout {
    static func padHeight(width: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let wide = width * 9 / 16
        if wide >= screenHeight * 0.5 { return min(wide, screenHeight * 0.8) }
        return min(screenHeight * 0.78, width)
    }
}

/// Round Liquid Glass button (the carousel's ••• and the game page's)
struct RoundGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Muted trailer drawn with AVPlayerLayer (fills the slide, no controls)
struct TrailerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

// MARK: - Cards (Apple TV style)

/// Ready to Play: landscape card with the game's art and logo, and a status bar at the bottom
/// (achievements progress, hours played, ••• menu), like the Apple TV app's Continue Watching cards
struct ShelfCard: View {
    let game: GameItem
    let selected: Bool
    let height: CGFloat
    @ObservedObject var model: HomeModel
    @ObservedObject private var steam = SteamManager.shared
    @ObservedObject private var steamArt = SteamOnlyArtwork.shared

    static func width(for height: CGFloat) -> CGFloat { (height * 1.43).rounded() }

    var body: some View {
        let width = Self.width(for: height)
        ZStack(alignment: .bottom) {
            ArtworkImage(path: game.artPath("hero") ?? game.artPath("grid"), fallbackText: game.name,
                         remoteURL: game.isInstalled ? nil : game.steamAppId.flatMap { SteamManager.heroURL($0) })
                .frame(width: width, height: height)
                .clipped()
                .onAppear { steamArt.ensure(game) }

            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)

            if let logo = ArtworkCache.shared.image(game.artPath("logo")) {
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width * 0.72, maxHeight: height * 0.34)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 26)
            }

            HStack(spacing: 8) {
                if let stats = achievements {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 30, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: max(4, 30 * CGFloat(stats.unlockedCount) / CGFloat(max(stats.achievements.count, 1))), height: 4)
                        }
                        .accessibilityLabel("\(stats.unlockedCount) of \(stats.achievements.count) achievements")
                }
                Text(status)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    GameMenuItems(game: game, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Game options")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 9)

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
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: width, height: height)
        .opacity(game.hidden ? 0.45 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(selected ? 0.95 : 0.12), lineWidth: selected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(0.4), radius: selected ? 10 : 5, y: 4)
        .scaleEffect(selected ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(game.name + (game.running ? ", running" : "") + ", " + status)
        .task(id: game.steamAppId) {
            if let appid = game.steamAppId, steam.isConfigured { await steam.loadAchievements(appid) }
        }
    }

    private var achievements: SteamAppStats? {
        guard let appid = game.steamAppId, let stats = steam.achievements[appid], !stats.achievements.isEmpty else { return nil }
        return stats
    }

    private var status: String {
        if game.running { return "Running" }
        if let appid = game.steamAppId, let owned = steam.owned(appid), owned.playtimeForever > 0 {
            return SteamManager.formatPlaytime(owned.playtimeForever)
        }
        if let last = model.effectiveLastPlayed(game) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: last, relativeTo: Date())
        }
        return "Not played yet"
    }
}

/// Library and Search: portrait cover (Steam's or SteamGridDB's) with the hours played at the bottom,
/// like the Apple TV app's posters
struct PosterCard: View {
    let game: GameItem
    let height: CGFloat
    var showsReadyBadge = false
    @ObservedObject private var steam = SteamManager.shared
    @ObservedObject private var steamArt = SteamOnlyArtwork.shared

    var body: some View {
        let width = (height * 2 / 3).rounded()
        ZStack(alignment: .bottom) {
            ArtworkImage(path: game.artPath("grid"), fallbackText: game.name,
                         remoteURL: game.isInstalled ? nil : game.steamAppId.flatMap { SteamManager.coverURL($0) })
                .frame(width: width, height: height)
                .clipped()
                .onAppear { steamArt.ensure(game) }

            if let hours = hours {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.3)
                Text(hours)
                    .font(.system(size: height > 200 ? 13 : 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                if showsReadyBadge && game.isInstalled {
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
                        .accessibilityLabel("Ready to Play")
                }
                Spacer(minLength: 0)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: width, height: height)
        .opacity(game.hidden ? 0.45 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name + (hours.map { ", " + $0 } ?? "") + (game.isInstalled ? ", ready to play" : ""))
        .accessibilityAddTraits(.isButton)
    }

    /// Hours played on Steam; nothing when the game hasn't been played
    private var hours: String? {
        guard let appid = game.steamAppId, let owned = steam.owned(appid), owned.playtimeForever > 0 else { return nil }
        return SteamManager.formatPlaytime(owned.playtimeForever) + " played"
    }
}
