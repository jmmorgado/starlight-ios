//
//  StarlightSteam.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Steam (account, owned games, recently played, achievements)

/// Stores the Steam Web API key in the iPhone's Keychain (never in UserDefaults or the repo)
enum SteamKeychain {
    private static let service = "Starlight.Steam"
    private static let account = "WebAPIKey"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(key.utf8)
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct SteamOwnedGame: Codable, Equatable {
    let appid: Int
    let name: String
    /// Minutes
    let playtimeForever: Int
    let lastPlayed: Date?
}

struct SteamRecentGame: Codable, Equatable {
    let appid: Int
    let name: String
    /// Minutes in the last two weeks
    let playtimeTwoWeeks: Int
    let playtimeForever: Int
}

struct SteamCache: Codable {
    var steamID: String
    var personaName: String
    var profilePublic: Bool
    var owned: [SteamOwnedGame]
    var recent: [SteamRecentGame]
    var updated: Date
}

/// Talks to the Steam Web API and keeps a local cache. Feeds Home, Library and the game page.
final class SteamManager: ObservableObject {
    static let shared = SteamManager()

    @Published private(set) var cache: SteamCache? {
        didSet { rebuildIndex() }
    }
    /// appid -> game, rebuilt when the cache changes (Home and Library look games up on every render)
    private var ownedIndex: [Int: SteamOwnedGame] = [:]
    private var recentIndex: [Int: SteamRecentGame] = [:]
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasKey = SteamKeychain.load() != nil
    @Published private(set) var achievements: [Int: SteamAppStats] = [:]
    private var loadingAchievements: Set<Int> = []

    private static let steamIDKey = "StarlightSteamID"
    private static let staleAfter: TimeInterval = 3 * 60 * 60

    var steamID: String? { UserDefaults.standard.string(forKey: Self.steamIDKey) }
    var isConfigured: Bool { hasKey && steamID != nil }
    var keySuffix: String {
        guard let key = SteamKeychain.load(), key.count >= 4 else { return "" }
        return String(key.suffix(4))
    }

    /// Owned games by appid
    func owned(_ appid: Int) -> SteamOwnedGame? { ownedIndex[appid] }
    func recent(_ appid: Int) -> SteamRecentGame? { recentIndex[appid] }

    private func rebuildIndex() {
        ownedIndex = Dictionary((cache?.owned ?? []).map { ($0.appid, $0) }, uniquingKeysWith: { first, _ in first })
        recentIndex = Dictionary((cache?.recent ?? []).map { ($0.appid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private init() {
        cache = Self.loadCache()
        rebuildIndex()   // didSet doesn't run during init
    }

    // MARK: Setup

    /// Saves the key (if given) and the profile, then checks them by downloading the games
    @MainActor
    func configure(apiKey: String, profile: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            SteamKeychain.save(key)
            hasKey = true
        }
        guard let storedKey = SteamKeychain.load() else {
            errorMessage = "Enter your Steam Web API key."
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let input = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = steamID
            if !input.isEmpty {
                id = try await resolveSteamID(input, key: storedKey)
            }
            guard let resolved = id else {
                errorMessage = "Enter your SteamID64 or profile name."
                return
            }
            UserDefaults.standard.set(resolved, forKey: Self.steamIDKey)
            try await refresh(key: storedKey, steamID: resolved)
        } catch {
            errorMessage = (error as? SteamError)?.message ?? "Couldn't reach Steam. Check your connection and try again."
        }
    }

    @MainActor
    func refreshIfStale() {
        guard isConfigured else { return }
        if let updated = cache?.updated, Date().timeIntervalSince(updated) < Self.staleAfter { return }
        Task { await refreshNow() }
    }

    @MainActor
    func refreshNow() async {
        guard let key = SteamKeychain.load(), let id = steamID, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await refresh(key: key, steamID: id)
        } catch {
            errorMessage = (error as? SteamError)?.message ?? "Couldn't reach Steam. Check your connection and try again."
        }
    }

    @MainActor
    func remove() {
        achievements = [:]
        SteamKeychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.steamIDKey)
        hasKey = false
        cache = nil
        errorMessage = nil
        try? FileManager.default.removeItem(at: Self.cacheURL.deletingLastPathComponent())
    }

    // MARK: Steam Web API

    struct SteamError: Error {
        let message: String
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.steampowered.com/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw SteamError(message: "Steam rejected the API key. Check it at steamcommunity.com/dev/apikey.")
        }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SteamError(message: "Steam didn't answer as expected (HTTP \(status)). Try again later.")
        }
        return json
    }

    /// Accepts a SteamID64, a profile URL (/profiles/… or /id/…) or a custom profile name
    private func resolveSteamID(_ input: String, key: String) async throws -> String {
        var text = input
        if let range = text.range(of: "/profiles/") {
            text = String(text[range.upperBound...]).components(separatedBy: "/").first ?? ""
        } else if let range = text.range(of: "/id/") {
            text = String(text[range.upperBound...]).components(separatedBy: "/").first ?? ""
        }
        if text.count == 17, text.allSatisfy(\.isNumber) {
            return text
        }
        let json = try await get("ISteamUser/ResolveVanityURL/v1/", ["key": key, "vanityurl": text])
        let response = json["response"] as? [String: Any]
        if (response?["success"] as? Int) == 1, let id = response?["steamid"] as? String {
            return id
        }
        throw SteamError(message: "No Steam profile called \u{201C}\(text)\u{201D}. Use your SteamID64 or the name in your profile URL.")
    }

    @MainActor
    private func refresh(key: String, steamID: String) async throws {
        // Profile name and visibility
        let summary = try await get("ISteamUser/GetPlayerSummaries/v2/", ["key": key, "steamids": steamID])
        let players = (summary["response"] as? [String: Any])?["players"] as? [[String: Any]] ?? []
        guard let player = players.first else {
            throw SteamError(message: "Steam couldn't find that account.")
        }
        let personaName = player["personaname"] as? String ?? "Steam"

        let ownedJSON = try await get("IPlayerService/GetOwnedGames/v1/", [
            "key": key, "steamid": steamID, "include_appinfo": "1", "include_played_free_games": "1"
        ])
        let ownedResponse = ownedJSON["response"] as? [String: Any] ?? [:]
        // A private "Game details" setting returns an empty response
        let profilePublic = ownedResponse["game_count"] != nil
        let owned: [SteamOwnedGame] = (ownedResponse["games"] as? [[String: Any]] ?? []).compactMap { game in
            guard let appid = game["appid"] as? Int else { return nil }
            let last = (game["rtime_last_played"] as? Double) ?? 0
            return SteamOwnedGame(appid: appid,
                                  name: game["name"] as? String ?? "",
                                  playtimeForever: game["playtime_forever"] as? Int ?? 0,
                                  lastPlayed: last > 0 ? Date(timeIntervalSince1970: last) : nil)
        }

        let recentJSON = try await get("IPlayerService/GetRecentlyPlayedGames/v1/", ["key": key, "steamid": steamID])
        let recent: [SteamRecentGame] = ((recentJSON["response"] as? [String: Any])?["games"] as? [[String: Any]] ?? []).compactMap { game in
            guard let appid = game["appid"] as? Int else { return nil }
            return SteamRecentGame(appid: appid,
                                   name: game["name"] as? String ?? "",
                                   playtimeTwoWeeks: game["playtime_2weeks"] as? Int ?? 0,
                                   playtimeForever: game["playtime_forever"] as? Int ?? 0)
        }

        let newCache = SteamCache(steamID: steamID, personaName: personaName, profilePublic: profilePublic,
                                  owned: owned, recent: recent, updated: Date())
        cache = newCache
        Self.saveCache(newCache)
        if !profilePublic {
            errorMessage = "Connected, but your Steam “Game details” are private, so playtime and achievements are empty. Set them to Public in Steam › Profile › Privacy Settings."
        }
    }

    // MARK: Achievements

    /// Player progress + names/icons + global rarity for one game, cached for a few hours
    @MainActor
    func loadAchievements(_ appid: Int) async {
        if let cached = achievements[appid], Date().timeIntervalSince(cached.updated) < Self.staleAfter { return }
        if let stored = Self.loadStats(appid), Date().timeIntervalSince(stored.updated) < Self.staleAfter {
            achievements[appid] = stored
            return
        }
        guard let key = SteamKeychain.load(), let id = steamID, !loadingAchievements.contains(appid) else { return }
        loadingAchievements.insert(appid)
        defer { loadingAchievements.remove(appid) }

        let app = String(appid)
        // Games without achievements answer with an error: that just means an empty list
        let player = (try? await get("ISteamUserStats/GetPlayerAchievements/v1/", ["key": key, "steamid": id, "appid": app, "l": "english"])) ?? [:]
        let schema = (try? await get("ISteamUserStats/GetSchemaForGame/v2/", ["key": key, "appid": app, "l": "english"])) ?? [:]
        let global = (try? await get("ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/", ["gameid": app])) ?? [:]

        var progress: [String: (Bool, Date?)] = [:]
        for item in ((player["playerstats"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []) {
            guard let name = item["apiname"] as? String else { continue }
            let time = (item["unlocktime"] as? Double) ?? 0
            progress[name] = (((item["achieved"] as? Int) ?? 0) == 1, time > 0 ? Date(timeIntervalSince1970: time) : nil)
        }
        var rarity: [String: Double] = [:]
        for item in ((global["achievementpercentages"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []) {
            guard let name = item["name"] as? String else { continue }
            if let value = item["percent"] as? Double {
                rarity[name] = value
            } else if let text = item["percent"] as? String, let value = Double(text) {
                rarity[name] = value
            }
        }
        let definitions = ((schema["game"] as? [String: Any])?["availableGameStats"] as? [String: Any])?["achievements"] as? [[String: Any]] ?? []
        let list: [SteamAchievement] = definitions.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let state = progress[name]
            return SteamAchievement(id: name,
                                    name: item["displayName"] as? String ?? name,
                                    description: item["description"] as? String ?? "",
                                    hidden: ((item["hidden"] as? Int) ?? 0) == 1,
                                    icon: item["icon"] as? String ?? "",
                                    iconGray: item["icongray"] as? String ?? "",
                                    achieved: state?.0 ?? false,
                                    unlocked: state?.1,
                                    percent: rarity[name])
        }
        let stats = SteamAppStats(appid: appid, achievements: list, updated: Date())
        achievements[appid] = stats
        Self.saveStats(stats)
    }

    private static func statsURL(_ appid: Int) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("achievements-\(appid).json")
    }

    private static func loadStats(_ appid: Int) -> SteamAppStats? {
        guard let data = try? Data(contentsOf: statsURL(appid)) else { return nil }
        return try? JSONDecoder().decode(SteamAppStats.self, from: data)
    }

    private static func saveStats(_ stats: SteamAppStats) {
        let url = statsURL(stats.appid)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stats) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Steam/cache.json")
    }

    private static func loadCache() -> SteamCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(SteamCache.self, from: data)
    }

    private static func saveCache(_ cache: SteamCache) {
        let url = cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct SteamSettingsRow: View {
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        HStack {
            Label("Steam", systemImage: "person.crop.circle")
            Spacer()
            Text(steam.isConfigured ? (steam.cache?.personaName ?? "Connected") : "Not set up")
                .foregroundStyle(.secondary)
        }
    }
}

struct SteamSettingsView: View {
    @ObservedObject private var steam = SteamManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var profile = ""
    @State private var confirmRemove = false
    @State private var removeArmed = false
    @FocusState private var field: Int?
    @ObservedObject private var focus = GameFocus.shared
    private let scope = "settings-steam"

    private var canConnect: Bool {
        !steam.busy && (steam.hasKey || !key.isEmpty) && (steam.steamID != nil || !profile.isEmpty)
    }

    private func connect() {
        let enteredKey = key
        let enteredProfile = profile
        Task {
            await steam.configure(apiKey: enteredKey, profile: enteredProfile)
            if steam.errorMessage == nil || steam.cache != nil {
                key = ""
                profile = ""
            }
        }
    }

    private var updatedText: String {
        guard let date = steam.cache?.updated else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                SecureField(steam.hasKey ? "New API key (optional)" : "Steam Web API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: 0)
                    .settingsFocus("steam-key", scope: scope) { field = 0 }
                TextField(steam.steamID ?? "SteamID64 or profile name", text: $profile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: 1)
                    .settingsFocus("steam-profile", scope: scope) { field = 1 }
                Button(action: connect) {
                    HStack {
                        Label(steam.isConfigured ? "Save & Test" : "Connect", systemImage: "checkmark.circle")
                        if steam.busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canConnect)
                .settingsFocus("steam-connect", scope: scope) { if canConnect { connect() } }
            } header: {
                Text("Steam account")
            } footer: {
                Text("Get a key at steamcommunity.com/dev/apikey (sign in; any domain name works). For your SteamID, paste your profile URL or the name in it. Your profile's \u{201C}Game details\u{201D} must be Public for playtime and achievements. The key is stored only in this device's Keychain.")
            }

            if let error = steam.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if steam.isConfigured {
                Section("Status") {
                    row("Account", steam.cache?.personaName ?? "—")
                    row("SteamID", steam.steamID ?? "—")
                    row("API key", "…" + steam.keySuffix)
                    row("Games owned", steam.cache.map { "\($0.owned.count)" } ?? "—")
                    row("Played in the last 2 weeks", steam.cache.map { "\($0.recent.count)" } ?? "—")
                    row("Updated", updatedText)
                }
                Section {
                    Button {
                        Task { await steam.refreshNow() }
                    } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(steam.busy)
                    .settingsFocus("steam-refresh", scope: scope) { Task { await steam.refreshNow() } }
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label(removeArmed ? "Press again to disconnect" : "Disconnect Steam", systemImage: "trash")
                    }
                    .settingsFocus("steam-remove", scope: scope) {
                        if removeArmed {
                            steam.remove()
                            removeArmed = false
                        } else {
                            removeArmed = true
                        }
                    }
                }
            }
        }
        .modifier(FocusScrollFollower(proxy: proxy))
        }
        .navigationTitle("Steam")
        .onChange(of: field) { focus.textEditing = $0 != nil }
        .settingsScreen(scope, dismiss: dismiss)
        .onChange(of: focus.focusedID) { id in
            if id != "steam-remove" { removeArmed = false }
        }
        .confirmationDialog("Disconnect Steam? The API key and the downloaded data are removed from this iPhone.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { steam.remove() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Steam achievements and collection helpers

struct SteamAchievement: Codable, Identifiable, Equatable {
    let id: String          // API name
    let name: String
    let description: String
    let hidden: Bool
    let icon: String
    let iconGray: String
    let achieved: Bool
    let unlocked: Date?
    let percent: Double?
}

struct SteamAppStats: Codable, Equatable {
    let appid: Int
    let achievements: [SteamAchievement]
    let updated: Date

    var unlockedCount: Int { achievements.filter(\.achieved).count }
}

extension SteamManager {
    static func formatPlaytime(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
    }

    /// Steam's own artwork for games that aren't on the PC (no key needed)
    static func coverURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg") }
    static func heroURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_hero.jpg") }
    static func logoURL(_ appid: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/logo.png") }
}

/// Library / Search entries: everything on the PC plus every Steam game you own, merged by appid
enum GameCollection {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", ready = "Ready to Play", notInstalled = "Not Installed"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", recent = "Recently Played", playtime = "Most Played"
        var id: String { rawValue }
    }

    static func entries(model: HomeModel, steam: SteamManager) -> [GameItem] {
        let installed = model.libraryGames
        let installedSteamIds = Set(model.games.compactMap(\.steamAppId))
        let steamOnly = (steam.cache?.owned ?? [])
            .filter { !installedSteamIds.contains($0.appid) }
            .map { GameItem.steamOnly(appid: $0.appid, name: $0.name) }
        return installed + steamOnly
    }

    static func apply(_ entries: [GameItem], filter: Filter, sort: Sort, steam: SteamManager, model: HomeModel) -> [GameItem] {
        let filtered: [GameItem]
        switch filter {
        case .all: filtered = entries
        case .ready: filtered = entries.filter(\.isInstalled)
        case .notInstalled: filtered = entries.filter { !$0.isInstalled }
        }
        func playtime(_ game: GameItem) -> Int { game.steamAppId.flatMap { steam.owned($0)?.playtimeForever } ?? 0 }
        func last(_ game: GameItem) -> Date { model.effectiveLastPlayed(game) ?? .distantPast }
        return filtered.sorted { a, b in
            switch sort {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .recent:
                let (x, y) = (last(a), last(b))
                return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .playtime:
                let (x, y) = (playtime(a), playtime(b))
                return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}

struct AchievementRow: View {
    let achievement: SteamAchievement

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: achievement.achieved ? achievement.icon : achievement.iconGray)) { phase in
                if let image = phase.image {
                    image.resizable()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.hidden && !achievement.achieved ? "Hidden achievement" : achievement.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(achievement.achieved ? .white : .white.opacity(0.7))
                if !(achievement.hidden && !achievement.achieved), !achievement.description.isEmpty {
                    Text(achievement.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if achievement.achieved, let date = achievement.unlocked {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12, weight: .semibold))
                }
                if let percent = achievement.percent {
                    Text(String(format: "%.1f%% of players", percent))
                        .font(.system(size: 11.5))
                        .foregroundStyle(percent < 10 ? starlightGold : .secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 560)
        .modifier(PanelGlass(corner: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Store page data (description, trailers, screenshots) and official news

struct SteamScreenshot: Codable, Equatable, Identifiable {
    let id: Int
    let thumb: String
    let full: String
}

struct SteamMovie: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let thumb: String
    /// HLS (H.264 + AAC): plays in AVPlayer as is
    let hls: String
    let highlight: Bool
}

struct SteamStoreInfo: Codable, Equatable {
    let appid: Int
    let shortDescription: String
    let aboutHTML: String
    let developers: [String]
    let publishers: [String]
    let genres: [String]
    let releaseDate: String
    let screenshots: [SteamScreenshot]
    let movies: [SteamMovie]
    let updated: Date

    /// The trailers shown on the game page: Steam's highlighted ones, at most three
    var featuredMovies: [SteamMovie] {
        let highlighted = movies.filter(\.highlight)
        return Array((highlighted.isEmpty ? movies : highlighted).prefix(3))
    }
}

struct SteamNewsItem: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let url: String
    let author: String
    let date: Date
    let contents: String
    let tags: [String]

    /// Steam's "patchnotes" tag isn't set on every patch, so the title counts too
    var isPatch: Bool {
        if tags.contains("patchnotes") { return true }
        let pattern = #"(?i)\b(patch|hotfix|changelog|change log|release notes|update\s*v?\d|v\d+(\.\d+)+)\b|\b\d+\.\d+(\.\d+)*\b"#
        return title.range(of: pattern, options: .regularExpression) != nil
    }
}

struct SteamNews: Codable, Equatable {
    let appid: Int
    let items: [SteamNewsItem]
    let updated: Date

    var patches: [SteamNewsItem] { items.filter(\.isPatch) }
    var news: [SteamNewsItem] { items.filter { !$0.isPatch } }
}

/// Store details and news for the game page. No key needed; cached on disk
/// (store details for a day, news for three hours).
final class SteamStore: ObservableObject {
    static let shared = SteamStore()

    @Published private(set) var info: [Int: SteamStoreInfo] = [:]
    @Published private(set) var news: [Int: SteamNews] = [:]
    /// appids Steam has no store page for (delisted, tools…), so the page doesn't keep asking
    private var missing: Set<Int> = []
    private var loading: Set<String> = []

    private static let infoStale: TimeInterval = 24 * 60 * 60
    private static let newsStale: TimeInterval = 3 * 60 * 60

    private static func fileURL(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Steam/\(name)")
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = fileURL(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @MainActor
    func load(_ appid: Int) async {
        async let a: Void = loadInfo(appid)
        async let b: Void = loadNews(appid)
        _ = await (a, b)
    }

    @MainActor
    private func loadInfo(_ appid: Int) async {
        if let cached = info[appid], Date().timeIntervalSince(cached.updated) < Self.infoStale { return }
        if missing.contains(appid) { return }
        let file = "store-\(appid).json"
        if let stored = Self.load(SteamStoreInfo.self, file), Date().timeIntervalSince(stored.updated) < Self.infoStale {
            info[appid] = stored
            return
        }
        let key = "info-\(appid)"
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }

        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appid)&l=english"),
              let root = await Self.json(url),
              let entry = root[String(appid)] as? [String: Any] else {
            // Offline: keep showing what we had
            if let stored = Self.load(SteamStoreInfo.self, file) { info[appid] = stored }
            return
        }
        guard (entry["success"] as? Bool) == true, let data = entry["data"] as? [String: Any] else {
            missing.insert(appid)
            return
        }
        let shots: [SteamScreenshot] = (data["screenshots"] as? [[String: Any]] ?? []).compactMap { item in
            guard let full = item["path_full"] as? String else { return nil }
            return SteamScreenshot(id: item["id"] as? Int ?? 0, thumb: item["path_thumbnail"] as? String ?? full, full: full)
        }
        let movies: [SteamMovie] = (data["movies"] as? [[String: Any]] ?? []).compactMap { item in
            guard let hls = item["hls_h264"] as? String else { return nil }
            return SteamMovie(id: item["id"] as? Int ?? 0, name: item["name"] as? String ?? "Trailer",
                              thumb: item["thumbnail"] as? String ?? "", hls: hls,
                              highlight: item["highlight"] as? Bool ?? false)
        }
        let result = SteamStoreInfo(
            appid: appid,
            shortDescription: SteamText.plain(fromHTML: data["short_description"] as? String ?? ""),
            aboutHTML: data["about_the_game"] as? String ?? data["detailed_description"] as? String ?? "",
            developers: data["developers"] as? [String] ?? [],
            publishers: data["publishers"] as? [String] ?? [],
            genres: (data["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String },
            releaseDate: (data["release_date"] as? [String: Any])?["date"] as? String ?? "",
            screenshots: shots,
            movies: movies,
            updated: Date())
        info[appid] = result
        Self.save(result, file)
    }

    @MainActor
    private func loadNews(_ appid: Int) async {
        if let cached = news[appid], Date().timeIntervalSince(cached.updated) < Self.newsStale { return }
        let file = "news-\(appid).json"
        if let stored = Self.load(SteamNews.self, file), Date().timeIntervalSince(stored.updated) < Self.newsStale {
            news[appid] = stored
            return
        }
        let key = "news-\(appid)"
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }

        // Only the developer's own announcements: without the feed filter Steam mixes in
        // articles from news sites in any language
        guard let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appid)&count=40&maxlength=0&feeds=steam_community_announcements&format=json"),
              let root = await Self.json(url),
              let list = (root["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]] else {
            if let stored = Self.load(SteamNews.self, file) { news[appid] = stored }
            return
        }
        let items: [SteamNewsItem] = list.compactMap { item in
            guard let gid = item["gid"] as? String, let title = item["title"] as? String else { return nil }
            return SteamNewsItem(id: gid,
                                 title: title,
                                 url: item["url"] as? String ?? "",
                                 author: item["author"] as? String ?? "",
                                 date: Date(timeIntervalSince1970: item["date"] as? Double ?? 0),
                                 contents: item["contents"] as? String ?? "",
                                 tags: item["tags"] as? [String] ?? [])
        }
        let result = SteamNews(appid: appid, items: items, updated: Date())
        news[appid] = result
        Self.save(result, file)
    }
}

/// Turns Steam's BBCode (news) and HTML (store descriptions) into readable text with bold, italics and links
enum SteamText {
    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                ("&reg;", "®"), ("&trade;", "™"), ("&copy;", "©"), ("&mdash;", "—"), ("&ndash;", "–"),
                                ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    /// Markdown special characters in the source text would be read as formatting
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for ch in text {
            if "*_`[]\\~".contains(ch) { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    private static func tidy(_ text: String) -> String {
        var result = replace(text, #"[ \t]+\n"#, "\n")
        result = replace(result, #"\n{3,}"#, "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plain(fromHTML html: String) -> String {
        tidy(decodeEntities(replace(replace(html, #"<br\s*/?>"#, "\n"), #"<[^>]+>"#, "")))
    }

    /// Placeholders Steam uses for images inside announcements
    static func imageURLs(inBBCode text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"\[img(?:\s+src=["']?([^"'\]\s]+)["']?)?[^\]]*\]([^\[]*)\[/img\]|\[img\s+src=["']?([^"'\]\s]+)"#, options: .caseInsensitive) else { return [] }
        var urls: [URL] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in [1, 2, 3] {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                let raw = String(text[range]).trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { continue }
                let resolved = raw.replacingOccurrences(of: "{STEAM_CLAN_IMAGE}", with: "https://clan.akamai.steamstatic.com/images/")
                if let url = URL(string: resolved), url.scheme?.hasPrefix("http") == true { urls.append(url) }
                break
            }
        }
        return urls
    }

    static func attributed(fromBBCode text: String) -> AttributedString {
        var s = escapeMarkdown(text)
        // The escape also hit the BBCode brackets: put them back
        s = s.replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
        s = replace(s, #"\[img[^\]]*\].*?\[/img\]|\[img[^\]]*\]"#, "")
        s = replace(s, #"\[(previewyoutube|video)[^\]]*\].*?\[/\1\]|\[(previewyoutube|video)[^\]]*\]"#, "")
        s = replace(s, #"\[h[1-6][^\]]*\](.*?)\[/h[1-6]\]"#, "\n\n**$1**\n")
        s = replace(s, #"\[b\](.*?)\[/b\]"#, "**$1**")
        s = replace(s, #"\[i\](.*?)\[/i\]"#, "*$1*")
        s = replace(s, #"\[url=["']?([^"'\]]+)["']?\](.*?)\[/url\]"#, "[$2]($1)")
        s = replace(s, #"\[url\](.*?)\[/url\]"#, "[$1]($1)")
        s = replace(s, #"\[\*\]"#, "\n• ")
        s = replace(s, #"\[/?(list|olist|ul|ol)[^\]]*\]"#, "\n")
        s = replace(s, #"\[/p\]|\[br\]|\[hr\]\[/hr\]|\[hr\]"#, "\n\n")
        s = replace(s, #"\[/?[a-z0-9]+(=[^\]]*)?[^\]]*\]"#, "")
        s = decodeEntities(replace(s, #"<[^>]+>"#, ""))
        return markdown(tidy(s))
    }

    static func attributed(fromHTML html: String) -> AttributedString {
        var s = escapeMarkdown(html)
        s = replace(s, #"<img[^>]*>"#, "")
        s = replace(s, #"<h[1-6][^>]*>(.*?)</h[1-6]>"#, "\n\n**$1**\n")
        s = replace(s, #"<(b|strong)>(.*?)</\1>"#, "**$2**")
        s = replace(s, #"<(i|em)>(.*?)</\1>"#, "*$2*")
        s = replace(s, #"<a [^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#, "[$2]($1)")
        s = replace(s, #"<li[^>]*>"#, "\n• ")
        s = replace(s, #"<br\s*/?>|</p>|</ul>|</ol>"#, "\n\n")
        s = decodeEntities(replace(s, #"<[^>]+>"#, ""))
        return markdown(tidy(s))
    }

    private static func markdown(_ text: String) -> AttributedString {
        if let result = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return result
        }
        return AttributedString(text)
    }
}
