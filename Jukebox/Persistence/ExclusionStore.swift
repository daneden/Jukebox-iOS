//
//  ExclusionStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 28/05/2026.
//
//  Actor wrapper around the SwiftData container holding `ExcludedItem`
//  rows. Songs mode reads `exclusions()` at deck-build time; Playlists
//  mode reads `blockedPlaylistIDs()`. Kept separate from
//  `TransitionFeedbackStore` so a schema change to one can't drag the other.

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
		// App Group container so the widget extension's controls see the same
		// removed songs/albums/artists the app set.
		let config = AppGroupStore.configuration("exclusions", schema: schema)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
		migrateLegacyExclusionsIfNeeded(schema: schema)
	}

	/// Copy pre-App-Group exclusions into the shared store once, so the user's
	/// removed items survive the move. Skips keys already present.
	private func migrateLegacyExclusionsIfNeeded(schema: Schema) {
		guard AppGroupStore.needsMigration("exclusions") else { return }
		AppGroupStore.markMigrated("exclusions")
		guard let context,
		      let legacy = try? ModelContainer(
		      	for: schema,
		      	configurations: [AppGroupStore.legacyConfiguration("exclusions", schema: schema)]
		      )
		else { return }
		let legacyContext = ModelContext(legacy)
		guard let rows = try? legacyContext.fetch(FetchDescriptor<ExcludedItem>()), !rows.isEmpty
		else { return }
		let existing = Set(((try? context.fetch(FetchDescriptor<ExcludedItem>())) ?? []).map(\.key))
		for row in rows where !existing.contains(row.key) {
			context.insert(ExcludedItem(key: row.key, kind: row.kind, label: row.label))
		}
		try? context.save()
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

	/// Inverse of the block helpers, for a future management screen.
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

	/// Song-mode exclusion snapshot: song ids, artist names, and album keys
	/// split out for O(1) grain checks. Playlist rows are ignored here.
	func exclusions() -> Exclusions {
		let rows = allRows()
		var songIDs = Set<String>()
		var artistNames = Set<String>()
		var albumKeys = Set<String>()
		for row in rows {
			switch row.kind {
			case .song:
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

	/// Raw playlist ids the user has excluded.
	func blockedPlaylistIDs() -> Set<String> {
		Set(allRows().filter { $0.kind == .playlist }.map { stripPrefix($0.key) })
	}

	private func allRows() -> [ExcludedItem] {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }
		return (try? context.fetch(FetchDescriptor<ExcludedItem>())) ?? []
	}

	/// Drop the leading `kind\u{1F}` namespace, recovering the raw id/name.
	/// Album keys carry two separators (kind + artist) so they're matched
	/// whole and never stripped.
	private func stripPrefix(_ key: String) -> String {
		guard let sep = key.firstIndex(of: "\u{1F}") else { return key }
		return String(key[key.index(after: sep)...])
	}
}
