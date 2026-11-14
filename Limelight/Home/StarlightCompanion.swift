//
//  StarlightCompanion.swift
//  Starlight
//

import SwiftUI
import UIKit

// MARK: - Second screen: companion panel on the iPhone while the stream plays on the TV

/// Shown on the iPhone when Settings › External Display is set to Second Screen and a TV is
/// connected (USB-C or AirPlay). The stream goes to the TV; the iPhone shows achievements,
/// per-game notes and the stream controls.
@objc(StarlightCompanionPanel)
final class StarlightCompanionPanel: NSObject {
    private let state: CompanionState
    private lazy var hosting: UIHostingController<CompanionView> = {
        let controller = UIHostingController(rootView: CompanionView(state: state))
        controller.view.backgroundColor = .black
        controller.overrideUserInterfaceStyle = .dark
        return controller
    }()

    /// "iphone" (move the stream back to the iPhone), "disconnect", "quit"
    @objc var onAction: ((String) -> Void)? {
        didSet { state.onAction = onAction }
    }

    @objc var viewController: UIViewController { hosting }

    /// steamAppId is 0 for games that aren't on Steam
    @objc init(gameName: String, steamAppId: Int, heroPath: String?) {
        state = CompanionState(gameName: gameName,
                               steamAppId: steamAppId > 0 ? steamAppId : nil,
                               heroPath: heroPath)
        super.init()
    }
}

/// Free-text notes per game, kept on the device
enum GameNotes {
    private static let key = "StarlightGameNotes"

    static func load(_ game: String) -> String {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[game] ?? ""
    }

    static func save(_ text: String, for game: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            all.removeValue(forKey: game)
        } else {
            all[game] = text
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}

final class CompanionState: ObservableObject {
    enum Tab: Hashable { case achievements, notes }

    let gameName: String
    let steamAppId: Int?
    let heroImage: UIImage?
    @Published var tab: Tab
    @Published var notes: String {
        didSet { GameNotes.save(notes, for: gameName) }
    }
    @Published var confirmQuit = false
    var onAction: ((String) -> Void)?

    init(gameName: String, steamAppId: Int?, heroPath: String?) {
        self.gameName = gameName
        self.steamAppId = steamAppId
        heroImage = heroPath.flatMap { UIImage(contentsOfFile: $0) }
        notes = GameNotes.load(gameName)
        tab = steamAppId != nil && SteamManager.shared.isConfigured ? .achievements : .notes
    }
}

struct CompanionView: View {
    @ObservedObject var state: CompanionState

    var body: some View {
        ZStack {
            background
            HStack(alignment: .top, spacing: 16) {
                sidePanel
                    .frame(width: 270)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
        }
        .animation(.easeInOut(duration: 0.2), value: state.confirmQuit)
    }

    private var background: some View {
        ZStack {
            Color.black
            if let image = state.heroImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 30)
                    .opacity(0.45)
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: Left: game, status and stream controls

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Playing on your TV", systemImage: "tv")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(starlightGold)
            Text(state.confirmQuit ? "Quit \(state.gameName)?" : state.gameName)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(3)
            if state.confirmQuit {
                Text("The game closes on your PC. Unsaved progress may be lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if state.confirmQuit {
                companionButton("Quit Game", "xmark.circle.fill", destructive: true) { state.onAction?("quit") }
                companionButton("Cancel", "arrow.uturn.backward") { state.confirmQuit = false }
            } else {
                companionButton("Show on iPhone", "iphone") { state.onAction?("iphone") }
                companionButton("Stop Streaming", "stop.fill") { state.onAction?("disconnect") }
                Text("The game keeps running on your PC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                companionButton("Quit Game", "xmark.circle.fill", destructive: true) { state.confirmQuit = true }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PanelGlass(corner: 24))
    }

    private func companionButton(_ title: String, _ symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
        }
        .modifier(CompanionButtonStyle(destructive: destructive))
    }

    // MARK: Right: achievements and notes

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.steamAppId != nil {
                Picker("", selection: $state.tab) {
                    Text("Achievements").tag(CompanionState.Tab.achievements)
                    Text("Notes").tag(CompanionState.Tab.notes)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            } else {
                Text("Notes").font(.system(size: 20, weight: .bold))
            }

            if state.tab == .achievements, let appid = state.steamAppId {
                CompanionAchievements(appid: appid)
            } else {
                CompanionNotes(state: state)
            }
        }
    }
}

private struct CompanionAchievements: View {
    let appid: Int
    @ObservedObject private var steam = SteamManager.shared
    @State private var refreshing = false

    var body: some View {
        Group {
            if !steam.isConfigured {
                message("Connect your Steam account in Settings › Steam to see achievements here.")
            } else if let stats = steam.achievements[appid] {
                if stats.achievements.isEmpty {
                    message("This game has no Steam achievements.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(stats.unlockedCount) of \(stats.achievements.count) unlocked")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Button {
                                Task { await refresh() }
                            } label: {
                                if refreshing {
                                    ProgressView()
                                } else {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                        .labelStyle(.iconOnly)
                                }
                            }
                            .disabled(refreshing)
                            .accessibilityLabel("Refresh achievements")
                        }
                        ProgressView(value: Double(stats.unlockedCount), total: Double(max(stats.achievements.count, 1)))
                            .tint(starlightGold)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(GameAchievementsSummary.sorted(stats.achievements)) { achievement in
                                    AchievementRow(achievement: achievement)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading achievements…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: appid) {
            await steam.loadAchievements(appid)
            // New unlocks show up while you play
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                if Task.isCancelled { break }
                await steam.loadAchievements(appid, force: true)
            }
        }
    }

    @MainActor
    private func refresh() async {
        refreshing = true
        await steam.loadAchievements(appid, force: true)
        refreshing = false
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct CompanionNotes: View {
    @ObservedObject var state: CompanionState
    @FocusState private var editing: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $state.notes)
                .focused($editing)
                .font(.system(size: 16))
                .modifier(ClearTextEditorBackground())
                .padding(10)
            if state.notes.isEmpty && !editing {
                Text("Notes for \(state.gameName): where you left off, codes, things to remember…")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelGlass(corner: 18))
        .overlay(alignment: .topTrailing) {
            if editing {
                Button("Done") { editing = false }
                    .font(.system(size: 15, weight: .semibold))
                    .modifier(CompanionButtonStyle(destructive: false))
                    .padding(8)
            }
        }
    }
}

private struct ClearTextEditorBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

private struct CompanionButtonStyle: ViewModifier {
    let destructive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).tint(destructive ? .red : nil)
        } else {
            content.buttonStyle(.bordered).tint(destructive ? .red : nil)
        }
    }
}
