//
//  StarlightFocus.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Controller glyphs

/// The connected controller's own button symbols (✕ ○ △ □ on PlayStation, A B Y X on Xbox)
enum PadGlyph {
    static var pad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad
    }

    static var search: String { pad?.buttonY.sfSymbolsName ?? "triangle.circle" }
    static var pc: String { pad?.buttonX.sfSymbolsName ?? "square.circle" }
    static var confirm: String { pad?.buttonA.sfSymbolsName ?? "a.circle" }
    static var play: String { pad?.rightTrigger.sfSymbolsName ?? "r2.rectangle.roundedtop" }
    static var options: String { pad?.buttonMenu.sfSymbolsName ?? "line.3.horizontal.circle" }
    static var leftShoulder: String { pad?.leftShoulder.sfSymbolsName ?? "l1.rectangle.roundedbottom" }
    static var rightShoulder: String { pad?.rightShoulder.sfSymbolsName ?? "r1.rectangle.roundedbottom" }
}

// MARK: - Focus engine (controller navigation)

struct FocusEntry: Equatable {
    let id: String
    let scope: String
    let rect: CGRect
}

struct FocusFrameKey: PreferenceKey {
    static var defaultValue: [FocusEntry] = []
    static func reduce(value: inout [FocusEntry], nextValue: () -> [FocusEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// Spatial focus for game controllers: elements report their frames, the D-pad moves to the
/// nearest element in that direction within the active scope (main screen, PC menu, game menu, tab bar).
final class GameFocus: ObservableObject {
    static let shared = GameFocus()

    enum Direction { case up, down, left, right }

    @Published var focusedID: String?
    @Published private(set) var scopes: [String] = []
    var entries: [FocusEntry] = []
    private var actions: [String: () -> Void] = [:]
    private var saved: [String: String] = [:]

    /// The focus space of the tab on screen ("main" = Home); each tab keeps its own,
    /// because the other tabs stay loaded and their cards would steal the selection
    var baseScope = "main"
    var activeScope: String { scopes.last ?? baseScope }

    private var grids: [String: (ids: [String], columns: Int)] = [:]
    private var adjusters: [String: (Int) -> Void] = [:]
    /// A Settings text field has the keyboard up
    var textEditing = false
    private var backHandlers: [String: () -> Void] = [:]

    func registerAdjust(_ id: String, _ adjust: ((Int) -> Void)?) -> Bool {
        adjusters[id] = adjust
        return true
    }

    func setBack(_ scope: String, _ handler: (() -> Void)?) {
        backHandlers[scope] = handler
    }

    /// ○ on a pushed Settings screen goes back
    func handleBack() -> Bool {
        guard let handler = backHandlers[activeScope] else { return false }
        handler()
        return true
    }

    func registerGrid(_ name: String, ids: [String], columns: Int) -> Bool {
        grids[name] = (ids, columns)
        return true
    }

    func register(_ id: String, _ action: @escaping () -> Void) -> Bool {
        actions[id] = action
        return true
    }

    func push(_ scope: String) {
        guard scopes.last != scope else { return }
        saved[activeScope] = focusedID
        scopes.append(scope)
        focusedID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if self?.focusedID == nil { self?.focusFirst() }
        }
    }

    func pop(_ scope: String) {
        guard let index = scopes.lastIndex(of: scope) else { return }
        scopes.remove(at: index)
        focusedID = saved[activeScope]
    }

    func focus(_ id: String) { focusedID = id }

    private var candidates: [FocusEntry] {
        entries.filter { $0.scope == activeScope && $0.rect.width > 0 }
    }

    func focusFirst() {
        let sorted = candidates.sorted {
            abs($0.rect.minY - $1.rect.minY) > 8 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        focusedID = sorted.first?.id
    }

    func move(_ direction: Direction) {
        // ← / → change the value of the focused setting instead of moving
        if (direction == .left || direction == .right), let id = focusedID,
           candidates.contains(where: { $0.id == id }), let adjust = adjusters[id] {
            adjust(direction == .left ? -1 : 1)
            return
        }
        if let id = focusedID, ["main", "library", "search"].contains(activeScope),
           let grid = grids.values.first(where: { $0.ids.contains(id) }), let index = grid.ids.firstIndex(of: id) {
            var target = index
            switch direction {
            case .left: target = index % grid.columns == 0 ? -1 : index - 1
            case .right: target = (index + 1) % grid.columns == 0 ? -1 : index + 1
            case .up: target = index - grid.columns
            case .down: target = index + grid.columns
            }
            if direction == .down && target >= grid.ids.count && index / grid.columns < (grid.ids.count - 1) / grid.columns {
                target = grid.ids.count - 1
            }
            if grid.ids.indices.contains(target) {
                focusedID = grid.ids[target]
            }
            return
        }
        let list = candidates
        guard !list.isEmpty else { return }
        guard let current = list.first(where: { $0.id == focusedID }) else {
            focusFirst()
            return
        }
        let from = CGPoint(x: current.rect.midX, y: current.rect.midY)
        var best: (FocusEntry, CGFloat)?
        for entry in list where entry.id != current.id {
            let to = CGPoint(x: entry.rect.midX, y: entry.rect.midY)
            let dx = to.x - from.x
            let dy = to.y - from.y
            let primary: CGFloat
            let secondary: CGFloat
            switch direction {
            case .right: primary = dx; secondary = abs(dy)
            case .left: primary = -dx; secondary = abs(dy)
            case .down: primary = dy; secondary = abs(dx)
            case .up: primary = -dy; secondary = abs(dx)
            }
            guard primary > 4 else { continue }
            // Stay in the same row/column when possible
            let score = primary + secondary * (direction == .left || direction == .right ? 4 : 1.2)
            if best == nil || score < best!.1 {
                best = (entry, score)
            }
        }
        if let target = best?.0 {
            focusedID = target.id
        }
    }

    func activate() {
        guard let id = focusedID, candidates.contains(where: { $0.id == id }) else {
            focusFirst()
            return
        }
        actions[id]?()
    }
}

struct GameFocusModifier: ViewModifier {
    let id: String
    let scope: String
    let corner: CGFloat
    let action: () -> Void
    var scales = true
    var adjust: ((Int) -> Void)? = nil
    @ObservedObject private var focus = GameFocus.shared
    @ObservedObject private var device = DeviceStatus.shared
    @Environment(\.focusTabScope) private var tabScope

    func body(content: Content) -> some View {
        let _ = focus.register(id, action)
        let _ = focus.registerAdjust(id, adjust)
        // "main" means "the tab I'm in"
        let scope = self.scope == "main" ? tabScope : self.scope
        let focused = device.controllerConnected && focus.activeScope == scope && focus.focusedID == id
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: FocusFrameKey.self,
                                           value: [FocusEntry(id: id, scope: scope, rect: geo.frame(in: .global))])
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                    .stroke(starlightGold, lineWidth: focused ? 3 : 0)
                    .padding(-4)
            )
            .scaleEffect(focused && scales ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .id(id)
    }
}

extension View {
    /// A Settings row reachable with the controller: ✕ runs `action`, ← / → call `adjust` (pickers, sliders, switches)
    func settingsFocus(_ id: String, scope: String, adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(GameFocusModifier(id: id, scope: scope, corner: 10, action: action, scales: false, adjust: adjust))
    }

    /// A pushed Settings screen: its own focus scope, and ○ goes back
    func settingsScreen(_ scope: String, dismiss: DismissAction) -> some View {
        self
            .onAppear {
                GameFocus.shared.push(scope)
                GameFocus.shared.setBack(scope) { dismiss() }
            }
            .onDisappear {
                GameFocus.shared.setBack(scope, nil)
                GameFocus.shared.pop(scope)
            }
    }
}

/// Scrolls a List/Form to the row the controller is on
struct FocusScrollFollower: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var focus = GameFocus.shared

    func body(content: Content) -> some View {
        content.onChange(of: focus.focusedID) { id in
            guard let id = id else { return }
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

private struct FocusTabScopeKey: EnvironmentKey {
    static let defaultValue = "main"
}

extension EnvironmentValues {
    /// The controller focus space of the tab a view lives in
    var focusTabScope: String {
        get { self[FocusTabScopeKey.self] }
        set { self[FocusTabScopeKey.self] = newValue }
    }
}

extension View {
    /// Makes the view reachable with the controller's D-pad; ✕ runs `action`
    func gameFocus(_ id: String, scope: String = "main", corner: CGFloat = 16, action: @escaping () -> Void) -> some View {
        modifier(GameFocusModifier(id: id, scope: scope, corner: corner, action: action))
    }
}

/// Reads the controller while the Starlight screens are on top (not during a stream, where
/// Moonlight's ControllerSupport takes over). Polling keeps it independent from the value-changed
/// handlers that ControllerSupport installs; the timer only runs while a controller is connected.
final class GamepadInput {
    static let shared = GamepadInput()

    enum Event { case up, down, left, right, confirm, back, search, pc, options, previousTab, nextTab, play }

    var handler: ((Event) -> Void)?
    private var timer: Timer?
    private var previous: Set<String> = []
    private var heldDirection: String?
    private var nextRepeat = Date.distantFuture

    var active = false {
        didSet {
            guard active != oldValue else { return }
            updateTimer()
        }
    }

    private init() {
        // Poll only while a controller is connected: no timer (and no battery cost) without one
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.updateTimer() }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.updateTimer() }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        previous = []
        heldDirection = nil
        guard active, !GCController.controllers().isEmpty else { return }
        disableSystemGestures()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
        // .common keeps it running while a scroll view is tracking
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func disableSystemGestures() {
        for controller in GCController.controllers() {
            for element in controller.physicalInputProfile.allElements {
                element.preferredSystemGestureState = .disabled
            }
        }
    }

    private func poll() {
        guard let pad = PadGlyph.pad else {
            previous = []
            return
        }
        var down: Set<String> = []
        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.6 { down.insert("up") }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.6 { down.insert("down") }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.6 { down.insert("left") }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.6 { down.insert("right") }
        if pad.buttonA.isPressed { down.insert("a") }
        if pad.buttonB.isPressed { down.insert("b") }
        if pad.buttonX.isPressed { down.insert("x") }
        if pad.buttonY.isPressed { down.insert("y") }
        if pad.buttonMenu.isPressed { down.insert("menu") }
        if pad.leftShoulder.isPressed { down.insert("l1") }
        if pad.rightShoulder.isPressed { down.insert("r1") }
        if pad.rightTrigger.isPressed { down.insert("r2") }

        let pressed = down.subtracting(previous)
        previous = down

        let map: [(String, Event)] = [
            ("up", .up), ("down", .down), ("left", .left), ("right", .right),
            ("a", .confirm), ("b", .back), ("y", .search), ("x", .pc),
            ("menu", .options), ("l1", .previousTab), ("r1", .nextTab), ("r2", .play)
        ]
        for (key, event) in map where pressed.contains(key) {
            handler?(event)
        }

        // Holding a direction repeats it
        let directions = ["up", "down", "left", "right"]
        if let held = directions.first(where: { down.contains($0) }) {
            if pressed.contains(held) || held != heldDirection {
                heldDirection = held
                nextRepeat = Date().addingTimeInterval(0.4)
            } else if Date() >= nextRepeat {
                nextRepeat = Date().addingTimeInterval(0.12)
                if let event = map.first(where: { $0.0 == held })?.1 { handler?(event) }
            }
        } else {
            heldDirection = nil
        }
    }
}

/// The PC list that drops down from the PC button
struct PCDropdown: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { model.closePC() }

            VStack(alignment: .leading, spacing: 6) {
                if !model.pairedHosts.isEmpty {
                    sectionTitle("Your PCs")
                    ForEach(model.pairedHosts) { host in
                        row("pc-host-\(host.id)",
                            title: host.name + (host.online ? "" : " · offline"),
                            symbol: host.id == model.selectedHost ? "checkmark" : "desktopcomputer") {
                            model.closePC()
                            model.onSelectHost?(host.id)
                        }
                    }
                }
                if !model.networkHosts.isEmpty {
                    sectionTitle("On Your Network")
                    ForEach(model.networkHosts) { host in
                        row("pc-net-\(host.id)", title: "\(host.name) · pair", symbol: "link") {
                            model.closePC()
                            model.onSelectHost?(host.id)
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                if let host = model.currentHost, host.paired, !host.online {
                    row("pc-wake", title: "Wake \(host.name)", symbol: "power") {
                        model.closePC()
                        model.hostAction("wake", host)
                    }
                }
                if let host = model.currentHost, host.paired {
                    row("pc-refresh", title: "Refresh Games", symbol: "arrow.clockwise") {
                        model.closePC()
                        model.hostAction("refresh", host)
                    }
                }
                row("pc-add", title: "Add PC by Address…", symbol: "plus") {
                    model.closePC()
                    model.command("addHost")
                }
            }
            .padding(12)
            .frame(width: 280)
            .modifier(PanelGlass(corner: 22))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 50)
        }
        .transition(.opacity)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private func row(_ id: String, title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gameFocus(id, scope: "pc", corner: 12, action: action)
    }
}

/// Game options as a navigable panel (used instead of the system menu when a controller is connected)
struct GameActionPanel: View {
    @ObservedObject var model: HomeModel
    let game: GameItem

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var destructive = false
    }

    private var items: [Item] {
        guard game.isInstalled else {
            // Steam games that aren't on the PC: only the artwork can be changed
            return [Item(id: "editArtwork", title: "Edit Artwork…", symbol: "photo.on.rectangle.angled")]
        }
        var list = [
            Item(id: "pin", title: game.pinned ? "Unpin" : "Pin", symbol: game.pinned ? "pin.slash" : "pin"),
            Item(id: "copyLink", title: "Copy Shortcut Link", symbol: "link"),
            Item(id: "saveIcon", title: "Save Icon to Photos", symbol: "photo"),
            Item(id: "editArtwork", title: "Edit Artwork…", symbol: "photo.on.rectangle.angled"),
            Item(id: "hide", title: game.hidden ? "Show Game" : "Hide Game", symbol: game.hidden ? "eye" : "eye.slash")
        ]
        if game.running {
            list.append(Item(id: "quit", title: "Quit Game", symbol: "xmark.circle", destructive: true))
        }
        return list
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { model.closeGameMenu() }

            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    Button { run(item.id) } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(item.destructive ? Color.red : Color.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .gameFocus("menu-\(item.id)", scope: "menu", corner: 12) { run(item.id) }
                }
            }
            .padding(14)
            .frame(width: 300)
            .modifier(PanelGlass(corner: 24))
        }
        .transition(.opacity)
    }

    private func run(_ id: String) {
        model.closeGameMenu()
        if id == "editArtwork" {
            model.editingGame = game
        } else {
            model.action(id, game)
        }
    }
}

struct PanelGlass: ViewModifier {
    let corner: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}
