//
//  StarlightRoot.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Root

enum StarlightTab: String, CaseIterable {
    case home, library, settings, search

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }

    /// Controller focus space for the tab
    var focusScope: String {
        switch self {
        case .home: return "main"
        case .library: return "library"
        case .settings: return "settings"
        case .search: return "search"
        }
    }

    /// The tabs shown in the tab bar (Search is the separate round button at the bottom trailing edge)
    static let barTabs: [StarlightTab] = [.home, .library, .settings]
}

struct HomeRootView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            tabs

            if model.pcExpanded {
                PCDropdown(model: model)
            }

            if let game = model.gameMenu {
                GameActionPanel(model: model, game: game)
            }
        }
        .onPreferenceChange(FocusFrameKey.self) { entries in
            GameFocus.shared.entries = entries
        }
        .tint(starlightGold)
        .preferredColorScheme(.dark)
        .sheet(item: $model.editingGame) { game in
            ArtworkEditorView(model: model, game: game)
                .preferredColorScheme(.dark)
        }
    }

    /// System tab bar (Liquid Glass on iOS 26). The Search tab is the round button at the bottom right
    /// that expands into the search field. L1 / R1 change the selection.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $model.tab) {
                Tab(StarlightTab.home.title, systemImage: StarlightTab.home.symbol, value: StarlightTab.home) {
                    StarlightStack { HomeTab(model: model).starlightToolbar(model).modifier(TabBarAutoHideVisibility()) }
                }
                Tab(StarlightTab.library.title, systemImage: StarlightTab.library.symbol, value: StarlightTab.library) {
                    StarlightStack {
                        LibraryTab(model: model)
                            .modifier(FadingTabTitle(title: "Library"))
                            .starlightToolbar(model)
                            .modifier(TabBarAutoHideVisibility())
                    }
                    .environment(\.focusTabScope, "library")
                }
                Tab(StarlightTab.settings.title, systemImage: StarlightTab.settings.symbol, value: StarlightTab.settings) {
                    SettingsTab(model: model)
                }
                Tab(value: StarlightTab.search, role: .search) {
                    StarlightStack { NativeSearchScreen(model: model).modifier(TabBarAutoHideVisibility()) }
                        .environment(\.focusTabScope, "search")
                }
            }
            // iPad: tab bar on top with the button that turns it into a sidebar (like the Apple TV app);
            // iPhone: the usual tab bar
            .tabViewStyle(.sidebarAdaptable)
            .modifier(TabBarMinimizeOnScroll())
        } else {
            TabView(selection: $model.tab) {
                StarlightStack { HomeTab(model: model).starlightToolbar(model) }
                    .tabItem { Label(StarlightTab.home.title, systemImage: StarlightTab.home.symbol) }
                    .tag(StarlightTab.home)
                StarlightStack {
                    LibraryTab(model: model)
                        .navigationTitle("Library")
                        .starlightToolbar(model)
                }
                .environment(\.focusTabScope, "library")
                .tabItem { Label(StarlightTab.library.title, systemImage: StarlightTab.library.symbol) }
                .tag(StarlightTab.library)
                SettingsTab(model: model)
                    .tabItem { Label(StarlightTab.settings.title, systemImage: StarlightTab.settings.symbol) }
                    .tag(StarlightTab.settings)
                StarlightStack { NativeSearchScreen(model: model) }
                    .environment(\.focusTabScope, "search")
                    .tabItem { Label(StarlightTab.search.title, systemImage: StarlightTab.search.symbol) }
                    .tag(StarlightTab.search)
            }
        }
    }
}

/// iOS 26: the tab bar shrinks to the selected tab's icon while scrolling down, like Photos
struct TabBarMinimizeOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

/// iPad: the tab bar on top slides away while you scroll down a tab and comes back when you
/// scroll up or reach the top, leaving the tab's title in the glass navigation bar (as on iPhone)
final class TabBarAutoHide: ObservableObject {
    static let shared = TabBarAutoHide()
    @Published private(set) var hidden = false
    /// 0 at the top → 1 after the first 60 pt: the tab's title fades in while the tab bar is still there
    @Published private(set) var titleProgress: Double = 0
    private var lastOffset: CGFloat = 0
    /// The tab bar only goes once the title is fully in
    private static let hideAfter: CGFloat = 120

    /// iPhone: the PC capsule shrinks to the PC (and the trailer sound) once the list has moved
    @Published private(set) var compact = false

    func update(offset: CGFloat) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            let value = offset > 30
            if value != compact {
                withAnimation(.easeInOut(duration: 0.25)) { compact = value }
            }
            return
        }
        let progress = (min(1, max(0, Double(offset - 8) / 60)) * 20).rounded() / 20
        if progress != titleProgress { titleProgress = progress }
        let delta = offset - lastOffset
        lastOffset = offset
        if offset < Self.hideAfter {
            set(false)
        } else if delta > 6 {
            set(true)
        } else if delta < -12 {
            set(false)
        }
    }

    func reset() {
        lastOffset = 0
        titleProgress = 0
        if compact { withAnimation(.easeInOut(duration: 0.25)) { compact = false } }
        set(false)
    }

    private func set(_ value: Bool) {
        guard hidden != value else { return }
        withAnimation(.easeInOut(duration: 0.25)) { hidden = value }
    }
}

/// Feeds a tab's scroll position to TabBarAutoHide (iOS 18+)
struct TabBarAutoHideScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                TabBarAutoHide.shared.update(offset: offset)
            }
        } else {
            content
        }
    }
}

/// Hides the tab bar while TabBarAutoHide says so (applied inside each tab's navigation stack)
struct TabBarAutoHideVisibility: ViewModifier {
    @ObservedObject private var state = TabBarAutoHide.shared

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(state.hidden ? .hidden : .visible, for: .tabBar)
        } else {
            content
        }
    }
}

/// iPad: as you scroll the glass bar comes in under the tab bar; once the tab bar has gone,
/// the tab's title fades in on the glass. iPhone: the usual title.
struct FadingTabTitle: ViewModifier {
    let title: String
    @ObservedObject private var state = TabBarAutoHide.shared

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        PadTabTitle(title: title)
                    }
                }
        } else {
            content.navigationTitle(title)
        }
    }
}

/// The iPad title: hidden while the tab bar shows, fades in just after it goes
struct PadTabTitle: View {
    let title: String
    @ObservedObject private var state = TabBarAutoHide.shared

    var body: some View {
        Text(title)
            .font(.headline)
            .opacity(state.hidden ? 1 : 0)
            .animation(state.hidden ? .easeInOut(duration: 0.45).delay(0.2) : .easeOut(duration: 0.15), value: state.hidden)
            .accessibilityHidden(!state.hidden)
    }
}

/// NavigationStack where available (needed for the iOS 26 toolbar and search behaviour)
struct StarlightStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// PC button and status together on the trailing side of the system navigation bar.
    /// On iOS 26 the system draws both as Liquid Glass and the PC menu opens with the native morph.
    func starlightToolbar(_ model: HomeModel) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same side, same group: iOS 26 draws the PC button and the status in one Liquid Glass capsule
                // One capsule: the PC menu with the status inside it, and the trailer's sound button
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    PCToolbarButton(model: model)
                    TrailerMuteButton()
                }
            }
    }

    func starlightStatusToolbar() -> some View {
        self.toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                StatusCluster()
            }
        }
    }
}

/// Search with the system search field (focus follows △ on the controller)
struct NativeSearchScreen: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        if #available(iOS 18.0, *) {
            FocusedSearch(model: model)
        } else {
            SearchTab(model: model)
                .navigationTitle("Search")
                .starlightToolbar(model)
                .searchable(text: $model.searchQuery, prompt: "Search game")
                .onSubmit(of: .search) { RecentSearches.add(model.searchQuery) }
        }
    }
}

@available(iOS 18.0, *)
private struct FocusedSearch: View {
    @ObservedObject var model: HomeModel
    @FocusState private var focused: Bool
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        SearchTab(model: model)
            .modifier(FadingTabTitle(title: "Search"))
            .starlightToolbar(model)
            // iPad: the field always open at the top (the tab bar's magnifier is the way in, so no second
            // magnifier in the toolbar). iPhone: the system's search tab field, as before
            .searchable(text: $model.searchQuery, placement: isPad ? .navigationBarDrawer(displayMode: .always) : .automatic,
                        prompt: "Search game")
            .onSubmit(of: .search) { RecentSearches.add(model.searchQuery) }
            .searchFocused($focused)
            .onAppear {
                focused = model.searchFieldFocused
                // Straight into typing when the tab opens (the field appears a moment after the tab)
                if isPad {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if model.tab == .search { focused = true }
                    }
                }
            }
            .onChange(of: model.searchFieldFocused) { _, value in
                if focused != value { focused = value }
            }
            .onChange(of: focused) { _, value in
                if model.searchFieldFocused != value { model.searchFieldFocused = value }
            }
    }
}

/// The PC button in the navigation bar: a native menu (opens with the system animation).
/// With a controller connected it shows □, and □ opens the navigable PC panel (system menus can't be driven by a controller).
struct PCToolbarButton: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var device = DeviceStatus.shared
    @ObservedObject private var bar = TabBarAutoHide.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone upright: the system status bar shows the time, network and battery.
    /// iPhone after scrolling: just the PC. iPad and the top of the list: everything.
    private var showsStatus: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return true }
        if verticalSizeClass == .regular { return false }
        return !bar.compact
    }

    var body: some View {
        // Always the system menu on touch; □ on the controller opens the navigable PC panel
        Group {
            Menu {
                if !model.pairedHosts.isEmpty {
                    Section(model.currentHost.map { "Connected to \($0.name)" } ?? "Your PCs") {
                        ForEach(model.pairedHosts) { host in
                            Button { model.onSelectHost?(host.id) } label: {
                                Label(host.name + (host.online ? "" : " · offline"),
                                      systemImage: host.id == model.selectedHost ? "checkmark" : "desktopcomputer")
                            }
                        }
                    }
                }
                if !model.networkHosts.isEmpty {
                    Section("On Your Network") {
                        ForEach(model.networkHosts) { host in
                            Button { model.onSelectHost?(host.id) } label: {
                                Label("\(host.name) · pair", systemImage: "link")
                            }
                        }
                    }
                }
                Section {
                    if let host = model.currentHost, host.paired, !host.online {
                        Button { model.hostAction("wake", host) } label: {
                            Label("Wake \(host.name)", systemImage: "power")
                        }
                    }
                    if let host = model.currentHost, host.paired {
                        Button { model.hostAction("refresh", host) } label: {
                            Label("Refresh Games", systemImage: "arrow.clockwise")
                        }
                    }
                    Button { model.command("addHost") } label: {
                        Label("Add PC by Address…", systemImage: "plus")
                    }
                }
            } label: {
                label
            }
            .accessibilityLabel(accessibility)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                    .offset(x: 3, y: 2)
            }
            if device.controllerConnected {
                Image(systemName: PadGlyph.pc)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if showsStatus {
                StatusIcons()
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        guard let host = model.currentHost else { return .gray }
        if !host.paired { return .orange }
        return host.online ? .green : .gray
    }

    private var accessibility: String {
        guard let host = model.currentHost else { return "Choose a PC" }
        return "PC \(host.name), " + (!host.paired ? "not paired" : (host.online ? "online" : "offline"))
    }
}
