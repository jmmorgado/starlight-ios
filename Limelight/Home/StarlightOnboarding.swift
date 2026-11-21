//
//  StarlightOnboarding.swift
//  Starlight
//

import SwiftUI
import UIKit
import GameController

// MARK: - Setup guide (first launch)

/// Guided first-launch setup: PC software, finding and pairing the PC, letting Starlight list
/// the games, Steam (optional), getting around with a controller and the shortcuts in a stream. Works on iPhone and iPad, in portrait
/// (stacked, actions pinned at the bottom) and landscape (copy on the left, card on the right).
/// Settings › About › Setup Guide opens it again.
enum OnboardingStep: Int, CaseIterable {
    case welcome, pcSoftware, findPC, pair, games, steam, controller, playing, done

    /// Position in the progress dots (1...7); the welcome screen has none
    var progress: Int { min(rawValue, OnboardingStep.dotCount) }
    static let dotCount = 7
}

struct OnboardingView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var steam = SteamManager.shared
    @ObservedObject private var device = DeviceStatus.shared
    @AppStorage("StarlightAutoWake") private var autoWake = true

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    @State private var chosenHostID: String?
    @State private var steamKey = ""
    @State private var steamProfile = ""
    @State private var streamingApp: StreamingApp = .vibepollo

    /// The app to install on the PC (step 2)
    enum StreamingApp {
        case vibepollo, sunshine
        var name: String { self == .vibepollo ? "Vibepollo" : "Sunshine" }
        var url: URL {
            URL(string: self == .vibepollo ? "https://github.com/Nonary/Vibepollo/releases"
                                           : "https://github.com/LizardByte/Sunshine/releases")!
        }
    }

    private static let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)
    private static let steamKeyURL = URL(string: "https://steamcommunity.com/dev/apikey")!

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                background
                Group {
                    if step == .welcome {
                        welcome(compact: geo.size.height < 500)
                    } else if landscape {
                        landscapeLayout
                    } else {
                        portraitLayout
                    }
                }
                .id(step)
                .transition(stepTransition)
            }
        }
        .preferredColorScheme(.dark)
        .tint(starlightGold)
        .onChange(of: model.hosts) { hosts in
            // Pairing done on the PC: move on by itself
            if step == .pair, let id = chosenHostID, hosts.first(where: { $0.id == id })?.paired == true {
                go(to: .games, forward: true)
            }
        }
    }

    // MARK: Navigation

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// The direction is set first, so the outgoing step also slides the right way
    private func go(to newStep: OnboardingStep, forward isForward: Bool) {
        forward = isForward
        DispatchQueue.main.async {
            withAnimation(Self.spring) { step = newStep }
        }
    }

    private func goBack() {
        switch step {
        case .pair:
            cancelPairing()
        case .games:
            go(to: .findPC, forward: false)
        default:
            if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
                go(to: previous, forward: false)
            }
        }
    }

    private func cancelPairing() {
        model.command("cancelPairing")
        model.pairingPIN = nil
        model.pairingError = nil
        go(to: .findPC, forward: false)
    }

    // MARK: Layouts

    private var background: some View {
        RadialGradient(colors: [Color(white: 0.23), Color(white: 0.11), Color(white: 0.03)],
                       center: UnitPoint(x: 0.78, y: 0.3), startRadius: 20, endRadius: 900)
            .ignoresSafeArea()
    }

    /// compact: short screens (iPhone in landscape) get a smaller logo and tighter spacing
    private func welcome(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            Image("StarlightLogo")
                .resizable()
                .frame(width: compact ? 76 : 104, height: compact ? 76 : 104)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                .accessibilityHidden(true)
            Text("Starlight")
                .font(.system(size: compact ? 36 : 44, weight: .bold))
                .padding(.top, compact ? 2 : 6)
            Text("Your PC game library on iPhone and iPad. Set it up in a couple of minutes.")
                .font(.system(size: compact ? 16 : 17))
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            primaryButton("Get Started") { go(to: .pcSoftware, forward: true) }
                .padding(.top, compact ? 6 : 14)
            Text("You'll need your PC turned on and on the same network.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Skip sits in the top corner, like on the other steps, away from the home indicator
        .overlay(alignment: .topTrailing) {
            skipButton
                .padding(.top, 16)
                .padding(.trailing, 28)
        }
    }

    /// Copy and actions on the left, the step's card on the right
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                header
                copy
                Spacer(minLength: 12)
                actions
            }
            .frame(maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)

            ScrollView(showsIndicators: false) {
                card
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Copy, then the card, with the actions pinned at the bottom
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    copy
                    card
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            actions
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if step != .done {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(OnboardingCircleButtonStyle())
                .accessibilityLabel("Back")
            }
            progressDots
            Spacer()
            if step != .done {
                skipButton
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(1...OnboardingStep.dotCount, id: \.self) { index in
                Capsule()
                    .fill(index == step.progress ? starlightGold
                          : Color.white.opacity(index < step.progress ? 0.55 : 0.22))
                    .frame(width: index == step.progress ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.progress) of \(OnboardingStep.dotCount)")
    }

    private var skipButton: some View {
        Button("Skip Setup") { model.finishOnboarding() }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(texts.eyebrow.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(starlightGold)
                .padding(.top, 6)
            Text(texts.title)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(texts.body)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var texts: (eyebrow: String, title: String, body: String) {
        switch step {
        case .welcome:
            return ("", "", "")
        case .pcSoftware:
            return ("Your PC", "Get your PC ready to stream",
                    "Starlight plays the games that run on your PC. Your PC needs a free app that streams them.")
        case .findPC:
            return ("Find your PC", "Choose your PC",
                    "Starlight looks for PCs on your Wi-Fi. Don't see yours? Check that it's on and the streaming app is running.")
        case .pair:
            return ("Pair", "Pair with \(chosenHost?.name ?? "your PC")",
                    "Pairing happens once. It lets only your devices connect to your PC.")
        case .games:
            return ("Your games", "Let Starlight see your games",
                    "Vibepollo keeps your game list private until you allow it. Turn on List applications for this device on your PC.")
        case .steam:
            return ("Optional", "Connect Steam",
                    "See playtime, achievements and recently played games, and your whole Steam collection in the Library.")
        case .controller:
            return ("Controller", "Get around with a controller",
                    "Connect it in Bluetooth settings and use it everywhere in Starlight, not just in games. Touch works too.")
        case .playing:
            return ("While you play", "Play your way",
                    "In a stream the controller belongs to the game. These shortcuts open Starlight's menu and the PC's Guide.")
        case .done:
            return ("Done", "You're all set",
                    "Your games are ready. Add a SteamGridDB key in Settings any time for artwork on games that aren't on Steam.")
        }
    }

    // MARK: Cards

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .welcome: EmptyView()
            case .pcSoftware: pcSoftwareCard
            case .findPC: findPCCard
            case .pair: pairCard
            case .games: gamesCard
            case .steam: steamCard
            case .controller: navigationCard
            case .playing: playingCard
            case .done: doneCard
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(OnboardingCardGlass())
    }

    private var pcSoftwareCard: some View {
        Group {
            cardLabel("On your PC, install one of these")
            Button { withAnimation(.easeInOut(duration: 0.2)) { streamingApp = .vibepollo } } label: {
                OnboardingRow(symbol: "desktopcomputer", title: "Vibepollo",
                              subtitle: "Lists and launches your games",
                              highlighted: streamingApp == .vibepollo) { EmptyView() }
            }
            .buttonStyle(.plain)
            Button { withAnimation(.easeInOut(duration: 0.2)) { streamingApp = .sunshine } } label: {
                OnboardingRow(symbol: "desktopcomputer", title: "Sunshine",
                              subtitle: "Works too, with fewer features",
                              highlighted: streamingApp == .sunshine) { EmptyView() }
            }
            .buttonStyle(.plain)
            shareLink
                .padding(.top, 6)
            Text("Send it to your PC by message or email.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var shareLink: some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: streamingApp.url) {
                Label("Share \(streamingApp.name) Link", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
        } else {
            Button {
                UIPasteboard.general.url = streamingApp.url
            } label: {
                Label("Copy \(streamingApp.name) Link", systemImage: "doc.on.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
        }
    }

    private var chosenHost: HostItem? {
        if let id = chosenHostID, let host = model.hosts.first(where: { $0.id == id }) {
            return host
        }
        return nil
    }

    /// The selected PC, or the best guess: an online PC not paired yet, else any online PC
    private var suggestedHost: HostItem? {
        chosenHost
            ?? model.hosts.first(where: { $0.online && !$0.paired })
            ?? model.hosts.first(where: { $0.online })
            ?? model.hosts.first
    }

    private var findPCCard: some View {
        Group {
            HStack {
                cardLabel("PCs on this network")
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            if model.hosts.isEmpty {
                Text("No PCs found yet. Make sure the PC is on, on the same Wi-Fi, and Vibepollo or Sunshine is running.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.vertical, 8)
            }
            ForEach(model.hosts) { host in
                Button {
                    chosenHostID = host.id
                } label: {
                    OnboardingRow(symbol: "desktopcomputer", title: host.name,
                                  subtitle: "\(host.online ? "Online" : "Offline") · \(host.paired ? "Paired" : "Not paired yet")",
                                  highlighted: host.id == suggestedHost?.id) {
                        if host.paired {
                            checkBadge
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Button { model.command("addHost") } label: {
                Label("Add PC by IP Address", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private var pairCard: some View {
        Group {
            cardLabel("Enter this PIN on your PC")
            if let pin = model.pairingPIN {
                HStack(spacing: 10) {
                    ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit))
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .frame(width: 58, height: 72)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
            } else if let error = model.pairingError {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { startPairing() }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Getting a PIN…").foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            }
            numberedLine(1, "On the PC, open the Vibepollo or Sunshine web page (localhost:47990).")
            numberedLine(2, "Go to PIN, type the code and give this device a name.")
            if model.pairingPIN != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(chosenHost?.name ?? "your PC")…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private func startPairing() {
        guard let host = suggestedHost else { return }
        chosenHostID = host.id
        model.pairingPIN = nil
        model.pairingError = nil
        model.hostAction("pair", host)
    }

    private var hostGames: [GameItem] {
        guard let id = chosenHost?.id ?? model.selectedHost else { return [] }
        return model.games.filter { $0.host == id && $0.isInstalled }
    }

    private var gamesCard: some View {
        Group {
            let host = chosenHost
            if host?.permissionDenied == true {
                cardLabel("In Vibepollo › Client Management › this device")
                OnboardingRow(symbol: "list.bullet.rectangle", title: "List applications",
                              subtitle: "Lets Starlight show your games", highlighted: true) {
                    // An illustration of the switch to turn on (on the PC, not here)
                    Capsule()
                        .fill(starlightGold)
                        .frame(width: 46, height: 28)
                        .overlay(Circle().fill(.white).padding(2), alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Text("Starlight can't see the games on \(host?.name ?? "your PC") yet.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                checkAgainButton
            } else if !hostGames.isEmpty {
                HStack(spacing: 10) {
                    checkBadge
                    Text("Games found on \(host?.name ?? "your PC")")
                        .font(.system(size: 15, weight: .semibold))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(hostGames.prefix(5)) { game in
                        ArtworkImage(path: game.artPath("grid"), fallbackText: game.name)
                            .aspectRatio(2 / 3, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading your games…").foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                checkAgainButton
            }
        }
    }

    private var checkAgainButton: some View {
        Button {
            if let host = chosenHost { model.hostAction("refresh", host) }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(OnboardingSecondaryButtonStyle())
    }

    private var steamCard: some View {
        Group {
            if steam.isConfigured && steam.errorMessage == nil && !steam.busy {
                HStack(spacing: 10) {
                    checkBadge
                    Text("Steam connected").font(.system(size: 15, weight: .semibold))
                }
                if let count = steam.cache?.owned.count, count > 0 {
                    Text("\(count) games in your Steam collection.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.72))
                }
            } else {
                fieldLabel("Steam Web API key")
                TextField("Paste your key", text: $steamKey)
                    .textFieldStyle(OnboardingFieldStyle())
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                Link("Get a free key on steamcommunity.com", destination: Self.steamKeyURL)
                    .font(.footnote)
                fieldLabel("SteamID or profile URL")
                    .padding(.top, 4)
                TextField("steamcommunity.com/id/…", text: $steamProfile)
                    .textFieldStyle(OnboardingFieldStyle())
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                if let error = steam.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(starlightGold)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.white.opacity(0.75))
                Text("Your profile's Game details must be public for playtime and achievements. The key stays in this device's Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 4)
        }
    }

    private var controllerStatus: some View {
        Group {
            if device.controllerConnected {
                HStack(spacing: 10) {
                    checkBadge
                    Text("\(GCController.current?.vendorName ?? "Controller") connected")
                        .font(.system(size: 15, weight: .semibold))
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(starlightGold)
                    Text("No controller connected yet")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    /// How the Starlight screens map to the controller (glyphs follow the connected controller)
    private var navigationCard: some View {
        Group {
            controllerStatus
            cardLabel("In Starlight")
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                buttonTile(PadGlyph.dpad, "Move between games")
                buttonTile(PadGlyph.confirm, "Open the game page")
                buttonTile(PadGlyph.play, "Play")
                buttonTile(PadGlyph.options, "Game options")
                buttonTile(PadGlyph.back, "Back")
                buttonTile(PadGlyph.search, "Search")
                buttonTile(PadGlyph.pc, "Choose the PC")
                buttonTile(PadGlyph.leftShoulder, "Change tab", second: PadGlyph.rightShoulder)
            }
            Text("In Settings, left and right change a value.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func buttonTile(_ symbol: String, _ title: String, second: String? = nil) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                if let second {
                    Image(systemName: second)
                }
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(starlightGold)
            .frame(minWidth: 30)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var playingCard: some View {
        Group {
            controllerStatus
            cardLabel("While you play")
                .padding(.top, 4)
            shortcutRow("Open the stream menu") { keyCap("Hold START") }
            shortcutRow("Send Guide to the PC") {
                HStack(spacing: 5) {
                    keyCap("START")
                    Text("+").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    keyCap("SELECT")
                }
            }
            shortcutRow("No controller? Pull the ••• button") {
                HStack(spacing: 6) {
                    Text("•••")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.18), in: Capsule())
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var doneCard: some View {
        Group {
            let paired = model.hosts.first(where: \.paired)
            doneRow("PC paired", status: paired?.name ?? "Not yet · Settings › PCs", ok: paired != nil)
            doneRow("Games", status: model.games.contains(where: \.isInstalled) ? "Ready to play" : "Check Settings › PCs",
                    ok: model.games.contains(where: \.isInstalled))
            doneRow("Steam", status: steam.isConfigured ? "Connected" : "Skipped · add it in Settings", ok: steam.isConfigured)
            doneRow("Artwork", status: "Steam artwork", ok: true)
            Toggle(isOn: $autoWake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake PC automatically").font(.system(size: 15, weight: .semibold))
                    Text("Turns the PC on when you start a game")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .tint(starlightGold)
            .padding(14)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 4)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch step {
            case .welcome:
                EmptyView()
            case .pcSoftware:
                primaryButton("My PC Is Ready") { go(to: .findPC, forward: true) }
            case .findPC:
                if let host = suggestedHost {
                    primaryButton(host.paired ? "Continue with \(host.name)" : "Pair \(host.name)") {
                        chosenHostID = host.id
                        if host.paired {
                            model.hostAction("refresh", host)
                            go(to: .games, forward: true)
                        } else {
                            startPairing()
                            go(to: .pair, forward: true)
                        }
                    }
                    .disabled(!host.online)
                    .opacity(host.online ? 1 : 0.5)
                }
            case .pair:
                secondaryButton("Cancel") { cancelPairing() }
            case .games:
                primaryButton("Continue") { go(to: .steam, forward: true) }
            case .steam:
                if steam.isConfigured && steam.errorMessage == nil && !steam.busy {
                    primaryButton("Continue") { go(to: .controller, forward: true) }
                } else {
                    primaryButton(steam.busy ? "Connecting…" : "Connect") {
                        Task { @MainActor in
                            await steam.configure(apiKey: steamKey, profile: steamProfile)
                            if steam.isConfigured && steam.errorMessage == nil {
                                go(to: .controller, forward: true)
                            }
                        }
                    }
                    .disabled(steam.busy || steamKey.trimmingCharacters(in: .whitespaces).isEmpty && !steam.hasKey)
                    secondaryButton("Skip for Now") { go(to: .controller, forward: true) }
                }
            case .controller:
                primaryButton("Continue") { go(to: .playing, forward: true) }
            case .playing:
                primaryButton("Continue") { go(to: .done, forward: true) }
            case .done:
                primaryButton("Open Starlight") { model.finishOnboarding() }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 22)
            .frame(minHeight: 46)
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 46)
        }
        .buttonStyle(OnboardingSecondaryButtonStyle())
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
    }

    /// Done / found marks follow the app's gold
    private var checkBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(Color(white: 0.08))
            .frame(width: 26, height: 26)
            .background(starlightGold, in: Circle())
            .accessibilityHidden(true)
    }

    private func numberedLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.16), in: Circle())
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(white: 0.08))
            .padding(.horizontal, 8)
            .frame(minWidth: 24, minHeight: 24)
            .background(.white, in: Capsule())
    }

    private func shortcutRow<Keys: View>(_ title: String, @ViewBuilder keys: () -> Keys) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            keys()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func doneRow(_ title: String, status: String, ok: Bool) -> some View {
        HStack(spacing: 12) {
            if ok {
                checkBadge
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Text(status)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A choice in a card; the selected one gets the app's gold ring
private struct OnboardingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    var highlighted = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background((highlighted ? starlightGold.opacity(0.3) : Color.white.opacity(0.14)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(highlighted ? 0.16 : 0.07),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(starlightGold, lineWidth: highlighted ? 2 : 0))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

private struct OnboardingCardGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(white: 0.05))
            .background(Color.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct OnboardingCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.white.opacity(configuration.isPressed ? 0.2 : 0.10), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct OnboardingFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}
