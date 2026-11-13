//
//  StarlightStreamMenu.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Stream menu (shown over a running stream)

/// Liquid Glass panel opened by swiping from the left edge or holding Start+Select on the controller.
/// Works by touch and, when a controller is connected, with the D-pad / left stick and the face buttons.
@objc(StarlightStreamMenu)
final class StarlightStreamMenu: NSObject {
    private let state: StreamMenuState
    private lazy var hosting: UIHostingController<StreamMenuView> = {
        let controller = UIHostingController(rootView: StreamMenuView(state: state))
        controller.view.backgroundColor = .clear
        controller.overrideUserInterfaceStyle = .dark
        return controller
    }()

    /// "resume", "keyboard", "stats", "disconnect", "quit"
    @objc var onAction: ((String) -> Void)? {
        didSet { state.onAction = onAction }
    }

    @objc var viewController: UIViewController { hosting }

    @objc init(gameName: String, statsVisible: Bool) {
        state = StreamMenuState(gameName: gameName, statsVisible: statsVisible)
        super.init()
    }

    @objc func setStatsVisible(_ visible: Bool) {
        state.statsVisible = visible
    }

    /// Controller input: "up", "down", "select", "back"
    @objc func navigate(_ action: String) {
        state.navigate(action)
    }
}

final class StreamMenuState: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        var prominent = false
        var destructive = false
    }

    let gameName: String
    @Published var statsVisible: Bool
    @Published var confirmQuit = false
    @Published var focus = 0
    var onAction: ((String) -> Void)?

    init(gameName: String, statsVisible: Bool) {
        self.gameName = gameName
        self.statsVisible = statsVisible
    }

    var items: [Item] {
        if confirmQuit {
            return [
                Item(id: "quit", title: "Quit Game", symbol: "xmark.circle.fill", destructive: true),
                Item(id: "cancelQuit", title: "Cancel", symbol: "arrow.uturn.backward")
            ]
        }
        return [
            Item(id: "resume", title: "Back to Game", symbol: "play.fill", prominent: true),
            Item(id: "keyboard", title: "Keyboard", symbol: "keyboard"),
            Item(id: "stats", title: statsVisible ? "Hide Statistics" : "Show Statistics", symbol: "chart.bar.xaxis"),
            Item(id: "disconnect", title: "Stop Streaming", symbol: "stop.fill"),
            Item(id: "askQuit", title: "Quit Game", symbol: "xmark.circle.fill", destructive: true)
        ]
    }

    func activate(_ id: String) {
        switch id {
        case "askQuit":
            confirmQuit = true
            focus = 1   // Cancel first, so a stray press doesn't quit
        case "cancelQuit":
            confirmQuit = false
            focus = items.firstIndex { $0.id == "askQuit" } ?? 0
        default:
            onAction?(id)
        }
    }

    func navigate(_ action: String) {
        let count = items.count
        switch action {
        case "up": focus = (focus - 1 + count) % count
        case "down": focus = (focus + 1) % count
        case "select":
            if items.indices.contains(focus) { activate(items[focus].id) }
        case "back":
            if confirmQuit { activate("cancelQuit") } else { onAction?("resume") }
        default: break
        }
    }
}

struct StreamMenuView: View {
    @ObservedObject var state: StreamMenuState
    @ObservedObject private var device = DeviceStatus.shared
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Tap outside the panel to go back to the game
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { state.onAction?("resume") }
                .accessibilityLabel("Back to game")
                .accessibilityAddTraits(.isButton)

            panel
                .offset(x: shown ? 0 : -360)

        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shown = true }
        }
        .animation(.easeInOut(duration: 0.15), value: state.focus)
        .animation(.easeInOut(duration: 0.2), value: state.confirmQuit)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.confirmQuit ? "Quit \(state.gameName)?" : state.gameName)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(2)
            if state.confirmQuit {
                Text("The game closes on your PC. Unsaved progress may be lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 4)

            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                if item.id == "disconnect" {
                    Spacer(minLength: 8)
                }
                menuButton(item, focused: device.controllerConnected && index == state.focus)
                if item.id == "disconnect" {
                    Text("The game keeps running on your PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            if state.confirmQuit {
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(StreamMenuGlass())
        .padding(.vertical, 12)
        .padding(.leading, 12)
    }

    private func menuButton(_ item: StreamMenuState.Item, focused: Bool) -> some View {
        Button(role: item.destructive ? .destructive : nil) {
            state.activate(item.id)
        } label: {
            Label(item.title, systemImage: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .modifier(StreamMenuButtonStyle(prominent: item.prominent, destructive: item.destructive))
        .overlay(
            Capsule()
                .stroke(starlightGold, lineWidth: focused ? 3 : 0)
        )
        .scaleEffect(focused ? 1.03 : 1)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

private struct StreamMenuGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

private struct StreamMenuButtonStyle: ViewModifier {
    let prominent: Bool
    let destructive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(starlightGold)
            } else {
                content.buttonStyle(.glass).tint(destructive ? .red : nil)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(starlightGold)
            } else {
                content.buttonStyle(.bordered).tint(destructive ? .red : nil)
            }
        }
    }
}
