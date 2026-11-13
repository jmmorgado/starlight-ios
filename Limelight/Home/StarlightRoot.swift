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
                    StarlightStack { HomeTab(model: model).starlightToolbar(model) }
                }
                Tab(StarlightTab.library.title, systemImage: StarlightTab.library.symbol, value: StarlightTab.library) {
                    StarlightStack {
                        LibraryTab(model: model)
                            .navigationTitle("Library")
                            .starlightToolbar(model)
                    }
                    .environment(\.focusTabScope, "library")
                }
                Tab(StarlightTab.settings.title, systemImage: StarlightTab.settings.symbol, value: StarlightTab.settings) {
                    SettingsTab(model: model)
                }
                Tab(value: StarlightTab.search, role: .search) {
                    StarlightStack { NativeSearchScreen(model: model) }
                        .environment(\.focusTabScope, "search")
                }
            }
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    PCToolbarButton(model: model)
                    StatusCluster()
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
        }
    }
}

@available(iOS 18.0, *)
private struct FocusedSearch: View {
    @ObservedObject var model: HomeModel
    @FocusState private var focused: Bool

    var body: some View {
        SearchTab(model: model)
            .navigationTitle("Search")
            .starlightToolbar(model)
            .searchable(text: $model.searchQuery, prompt: "Search game")
            .searchFocused($focused)
            .onAppear { focused = model.searchFieldFocused }
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
