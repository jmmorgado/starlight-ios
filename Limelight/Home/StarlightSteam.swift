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

/// Playtime and achievements on the game page (Steam games only)
struct SteamStatsSection: View {
    let appid: Int
    @ObservedObject private var steam = SteamManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let owned = steam.owned(appid) {
                HStack(spacing: 22) {
                    stat(SteamManager.formatPlaytime(owned.playtimeForever), "Played")
                    if let recent = steam.recent(appid), recent.playtimeTwoWeeks > 0 {
                        stat(SteamManager.formatPlaytime(recent.playtimeTwoWeeks), "Last 2 weeks")
                    }
                    if let last = owned.lastPlayed {
                        stat(last.formatted(date: .abbreviated, time: .omitted), "Last played")
                    }
                }
            }

            if let stats = steam.achievements[appid] {
                if !stats.achievements.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Achievements")
                                .font(.system(size: 17, weight: .bold))
                            Spacer()
                            Text("\(stats.unlockedCount) of \(stats.achievements.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(stats.unlockedCount), total: Double(max(stats.achievements.count, 1)))
                            .tint(starlightGold)
                    }
                    .frame(maxWidth: 560)

                    ForEach(sorted(stats.achievements)) { achievement in
                        AchievementRow(achievement: achievement)
                            .gameFocus("ach-\(achievement.id)", scope: "detail", corner: 14) {}
                    }
                }
            } else if steam.isConfigured {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading Steam stats…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: appid) { await steam.loadAchievements(appid) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Unlocked first (most recent first), then locked from most to least common
    private func sorted(_ list: [SteamAchievement]) -> [SteamAchievement] {
        list.sorted { a, b in
            if a.achieved != b.achieved { return a.achieved }
            if a.achieved { return (a.unlocked ?? .distantPast) > (b.unlocked ?? .distantPast) }
            return (a.percent ?? 0) > (b.percent ?? 0)
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
