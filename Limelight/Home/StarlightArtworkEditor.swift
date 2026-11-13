//
//  StarlightArtworkEditor.swift
//  Starlight
//

import SwiftUI
import UIKit
import Network
import GameController
import Security

// MARK: - Edit artwork (manual SteamGridDB match and images)

struct ArtworkEditorView: View {
    @ObservedObject var model: HomeModel
    let game: GameItem
    @Environment(\.dismiss) private var dismiss

    struct SearchResult: Identifiable, Hashable {
        let id: String
        let name: String
        let year: String
        let verified: Bool
    }

    struct ImageOption: Identifiable, Hashable {
        var id: String { url }
        let url: String
        let thumb: String
    }

    @State private var configured = true
    @State private var matchId = ""
    @State private var matchName = ""
    @State private var term = ""
    @State private var searching = false
    @State private var searchFailed = false
    @State private var results: [SearchResult] = []
    @State private var applyingMatch: String?
    @State private var options: [String: [ImageOption]] = [:]
    @State private var loadingKinds: Set<String> = []
    @State private var chosen: [String: String] = [:]
    @State private var applyingImage: String?

    struct ArtKind: Identifiable {
        var id: String { kind }
        let kind: String
        let title: String
        let aspect: CGFloat
        let footer: String
    }

    private let kinds: [ArtKind] = [
        ArtKind(kind: "hero", title: "Background", aspect: 16.0 / 9.0,
                footer: "Fills the Home screen and the loading screen, and is used for the game cards in Continue Playing and All Games."),
        ArtKind(kind: "grid", title: "Portrait Cover", aspect: 2.0 / 3.0,
                footer: "Vertical cover with the logo built in, used in Library."),
        ArtKind(kind: "logo", title: "Logo", aspect: 2.0,
                footer: "Shown over the background on the Home screen and on the game cards."),
        ArtKind(kind: "icon", title: "Icon", aspect: 1.0,
                footer: "Used for Save Icon to Photos and in the Shortcuts app.")
    ]

    var body: some View {
        NavigationView {
            List {
                if !configured {
                    Section {
                        Text("Add your SteamGridDB API key in Settings › Game Artwork first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        HStack {
                            Text("Matched to")
                            Spacer()
                            Text(matchName.isEmpty ? "No match" : matchName)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            TextField("Search SteamGridDB", text: $term)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit(search)
                            if searching {
                                ProgressView()
                            } else {
                                Button("Search", action: search)
                                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if searchFailed {
                            Text("Couldn't reach SteamGridDB. Try again.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { result in
                            Button {
                                applyMatch(result)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name)
                                            .foregroundStyle(.primary)
                                        if !result.year.isEmpty {
                                            Text(result.year)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if applyingMatch == result.id {
                                        ProgressView()
                                    } else if result.id == matchId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(starlightGold)
                                    }
                                }
                            }
                            .disabled(applyingMatch != nil)
                        }
                    } header: {
                        Text("Game")
                    } footer: {
                        Text("Pick the right game if the artwork belongs to a different version or edition. Your choice is kept when artwork is downloaded again.")
                    }

                    ForEach(kinds) { item in
                        Section {
                            imageStrip(kind: item.kind, aspect: item.aspect)
                        } header: {
                            Text(item.title)
                        } footer: {
                            Text(item.footer)
                        }
                    }
                }
            }
            .navigationTitle(game.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func imageStrip(kind: String, aspect: CGFloat) -> some View {
        let height: CGFloat = kind == "grid" ? 150 : (kind == "icon" ? 80 : 90)
        let width = height * aspect
        if loadingKinds.contains(kind) {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(height: height)
        } else if let list = options[kind], !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(list) { option in
                        Button {
                            applyImage(kind: kind, option: option)
                        } label: {
                            ZStack {
                                Color(white: kind == "logo" || kind == "icon" ? 0.18 : 0.12)
                                AsyncImage(url: URL(string: option.thumb)) { phase in
                                    if let image = phase.image {
                                        image.resizable()
                                            .aspectRatio(contentMode: kind == "logo" || kind == "icon" ? .fit : .fill)
                                    } else if phase.error != nil {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ProgressView()
                                    }
                                }
                                .padding(kind == "logo" ? 8 : 0)
                                if applyingImage == option.url {
                                    Color.black.opacity(0.5)
                                    ProgressView()
                                }
                            }
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(chosen[kind] == option.url ? starlightGold : .white.opacity(0.12),
                                            lineWidth: chosen[kind] == option.url ? 3 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingImage != nil)
                        .accessibilityLabel("\(kind) option")
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: height + 8)
        } else {
            Text(matchId.isEmpty ? "Pick a game above first." : "Nothing available.")
                .foregroundStyle(.secondary)
        }
    }

    private func request(_ action: String, _ params: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
        guard let handler = model.artworkRequest else { return }
        handler(action, params, reply)
    }

    private func load() {
        term = game.name
        request("info", ["name": game.name]) { info in
            configured = (info["configured"] as? NSNumber)?.boolValue ?? false
            matchId = info["matchId"] as? String ?? ""
            matchName = info["matchName"] as? String ?? ""
            if configured {
                search()
                loadOptions()
            }
        }
    }

    private func search() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true
        searchFailed = false
        request("search", ["term": query]) { reply in
            searching = false
            guard let list = reply["results"] as? [[String: Any]] else {
                searchFailed = true
                return
            }
            results = list.compactMap { dict in
                guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                return SearchResult(id: id, name: name, year: dict["year"] as? String ?? "",
                                    verified: (dict["verified"] as? NSNumber)?.boolValue ?? false)
            }
        }
    }

    private func loadOptions() {
        guard !matchId.isEmpty else { return }
        for item in kinds {
            let kind = item.kind
            loadingKinds.insert(kind)
            request("options", ["name": game.name, "kind": kind]) { reply in
                loadingKinds.remove(kind)
                let list = reply["options"] as? [[String: Any]] ?? []
                options[kind] = list.compactMap { dict in
                    guard let url = dict["url"] as? String else { return nil }
                    return ImageOption(url: url, thumb: dict["thumb"] as? String ?? url)
                }
            }
        }
    }

    private func applyMatch(_ result: SearchResult) {
        applyingMatch = result.id
        request("setMatch", ["name": game.name, "gameId": result.id, "gameName": result.name]) { _ in
            applyingMatch = nil
            matchId = result.id
            matchName = result.name
            chosen = [:]
            options = [:]
            loadOptions()
        }
    }

    private func applyImage(kind: String, option: ImageOption) {
        applyingImage = option.url
        request("setImage", ["name": game.name, "kind": kind, "url": option.url]) { reply in
            applyingImage = nil
            if (reply["ok"] as? NSNumber)?.boolValue ?? false {
                chosen[kind] = option.url
            }
        }
    }
}
