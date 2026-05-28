//
//  ExclusionStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 28/05/2026.
//
//  Actor wrapper around the SwiftData container holding `ExcludedItem`
//  rows — the songs, albums, artists, and playlists the user has flagged
//  ineligible from the dial's context menu.
//
//  Songs mode reads `exclusions()` at deck-build time and drops matching
//  candidates before scoring; Playlists mode reads `blockedPlaylistIDs()`
//  and filters the fetched collection. Kept separate from
//  `TransitionFeedbackStore` on purpose: a schema change to one store
//  shouldn't drag the other along (see that file for the full rationale).

import Foundation
import MusicKit
import SwiftData

actor ExclusionStore {
	static let shared = ExclusionStore()

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([ExcludedItem.self])
		// Named so this store gets its own sqlite file — see
		// `EmbeddingStore.ensureLoaded` for the full rationale.
		let config = ModelConfiguration("exclusions", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	// MARK: - Blocking

	func blockSong(id: String, label: String) {
		insert(key: ExcludedItem.songKey(id), kind: .song, label: label)
	}

	func blockArtist(name: String, label: String) {
		insert(key: ExcludedItem.artistKey(name), kind: .artist, label: label)
	}

	func blockAlbum(artist: String, title: String, label: String) {
		insert(key: ExcludedItem.albumKey(artist: artist, title: title), kind: .album, label: label)
	}

	func blockPlaylist(id: String, label: String) {
		insert(key: ExcludedItem.playlistKey(id), kind: .playlist, label: label)
	}

	/// Inverse of the block helpers. Not surfaced in the UI yet, but kept
	/// here so a future management screen can lift an exclusion without
	/// reaching into SwiftData.
	func unblock(key: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<ExcludedItem>(
			predicate: #Predicate { $0.key == key }
		)
		if let row = try? context.fetch(descriptor).first {
			context.delete(row)
			try? context.save()
		}
	}

	private func insert(key: String, kind: ExclusionKind, label: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<ExcludedItem>(
			predicate: #Predicate { $0.key == key }
		)
		if (try? context.fetch(descriptor).first) != nil { return }
		context.insert(ExcludedItem(key: key, kind: kind, label: label))
		try? context.save()
	}

	// MARK: - Snapshots

	/// Song-mode exclusion snapshot: song ids, artist names, and album
	/// keys split out so `Exclusions.excludes(song:)` can check each grain
	/// in O(1). Playlist rows are ignored here — they're Playlists-mode's
	/// concern via `blockedPlaylistIDs()`.
	func exclusions() -> Exclusions {
		let rows = allRows()
		var songIDs = Set<String>()
		var artistNames = Set<String>()
		var albumKeys = Set<String>()
		for row in rows {
			switch row.kind {
			case .song:
				// Strip the "song\u{1F}" namespace prefix back to the raw id.
				songIDs.insert(stripPrefix(row.key))
			case .artist:
				artistNames.insert(stripPrefix(row.key))
			case .album:
				albumKeys.insert(row.key)
			case .playlist:
				break
			}
		}
		return Exclusions(songIDs: songIDs, artistNames: artistNames, albumKeys: albumKeys)
	}

	/// Raw playlist ids the user has excluded. Playlists mode filters its
	/// fetched collection against this set.
	func blockedPlaylistIDs() -> Set<String> {
		Set(allRows().filter { $0.kind == .playlist }.map { stripPrefix($0.key) })
	}

	private func allRows() -> [ExcludedItem] {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }
		return (try? context.fetch(FetchDescriptor<ExcludedItem>())) ?? []
	}

	/// Drop the leading `kind\u{1F}` namespace from a key, recovering the
	/// raw id/name. Album keys carry two separators (kind + artist) so
	/// they're matched whole and never stripped.
	private func stripPrefix(_ key: String) -> String {
		guard let sep = key.firstIndex(of: "\u{1F}") else { return key }
		return String(key[key.index(after: sep)...])
	}
}
