//
//  StarlightAppIntents.swift
//  Starlight
//
//  Exposes the PC's games to the Shortcuts app, Spotlight and Siri.
//
//  The game list comes from a snapshot that MainFrameViewController writes to
//  UserDefaults ("StarlightGameCatalog") whenever a PC's app list changes, so this
//  file doesn't need to touch Core Data. Running the intent posts
//  "StarlightLaunchRequest", which AppDelegate turns into the same pending launch
//  used by starlight:// links and pinned games.
//

import AppIntents
import Foundation

private let catalogKey = "StarlightGameCatalog"

private struct CatalogEntry {
    let host: String
    let hostName: String
    let app: String
    let appName: String
    let artPath: String?

    var entityId: String { "\(host)|\(app)" }

    static func loadAll() -> [CatalogEntry] {
        guard let raw = UserDefaults.standard.array(forKey: catalogKey) as? [[String: String]] else {
            return []
        }
        return raw.compactMap { dict in
            guard let host = dict["host"], let app = dict["app"], let appName = dict["appName"] else {
                return nil
            }
            return CatalogEntry(host: host,
                                hostName: dict["hostName"] ?? "",
                                app: app,
                                appName: appName,
                                artPath: dict["artPath"])
        }
    }
}

@available(iOS 16.0, *)
struct GameEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static var defaultQuery = GameEntityQuery()

    let id: String
    let name: String
    let hostUUID: String
    let appId: String
    let hostName: String
    let artPath: String?

    fileprivate init(_ entry: CatalogEntry) {
        id = entry.entityId
        name = entry.appName
        hostUUID = entry.host
        appId = entry.app
        hostName = entry.hostName
        artPath = entry.artPath
    }

    var displayRepresentation: DisplayRepresentation {
        var image: DisplayRepresentation.Image? = nil
        if let artPath = artPath, FileManager.default.fileExists(atPath: artPath) {
            image = DisplayRepresentation.Image(url: URL(fileURLWithPath: artPath))
        }
        return DisplayRepresentation(title: "\(name)",
                                     subtitle: hostName.isEmpty ? nil : "\(hostName)",
                                     image: image)
    }
}

@available(iOS 16.0, *)
struct GameEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GameEntity] {
        let wanted = Set(identifiers)
        return CatalogEntry.loadAll().filter { wanted.contains($0.entityId) }.map(GameEntity.init)
    }

    func suggestedEntities() async throws -> [GameEntity] {
        CatalogEntry.loadAll().map(GameEntity.init)
    }

    func entities(matching string: String) async throws -> [GameEntity] {
        CatalogEntry.loadAll()
            .filter { $0.appName.localizedCaseInsensitiveContains(string) }
            .map(GameEntity.init)
    }
}

@available(iOS 16.0, *)
struct StartGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Game"
    static var description = IntentDescription("Starts streaming a game from your PC in Starlight, straight into the stream.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Game")
    var game: GameEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$game)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("StarlightLaunchRequest"),
                                        object: nil,
                                        userInfo: ["host": game.hostUUID, "app": game.appId])
        return .result()
    }
}

@available(iOS 16.0, *)
struct StarlightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartGameIntent(),
                    phrases: [
                        "Start \(\.$game) in \(.applicationName)",
                        "Play \(\.$game) in \(.applicationName)",
                        "Start a game in \(.applicationName)"
                    ])
    }
}

/// Called from Objective-C (via NSClassFromString) when the game catalog changes,
/// so Siri and Spotlight pick up the new game names.
@objc(StarlightIntentsBridge)
final class StarlightIntentsBridge: NSObject {
    @objc static func catalogDidChange() {
        if #available(iOS 16.0, *) {
            StarlightShortcuts.updateAppShortcutParameters()
        }
    }
}
