//
//  HistoryStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Actor over the SwiftData container of `HistoryPlaylist` rows; records
//  each Songs-mode play as a snapshotted runway.
//
//  Local-only (no CloudKit); reinstall loses history.

import Foundation
import MusicKit
import SwiftData

actor HistoryStore {
	static let shared = HistoryStore()

	/// Soft cap on stored entries; older rows are pruned on every insert.
	static let maxEntries = 200

	/// Window for treating a new play as a continuation of the most recent
	/// entry — long enough to catch flitting between seeds in one deck,
	/// short enough not to glue onto a play from this morning.
	static let mergeWindow: TimeInterval = 15 * 60

	/// Minimum overlap (intersection over min set size) for two runways to
	/// count as the same session. Adjacent seeds in the same deck overlap
	/// ~95%; a post-shuffle deck drops near zero — 50% separates them.
	static let mergeOverlapThreshold = 0.5

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([HistoryPlaylist.self, HistorySong.self])
		// App Group container so the app, its App Intents, and the widget
		// extension share one history file.
		let config = AppGroupStore.configuration("history", schema: schema)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
		migrateLegacyHistoryIfNeeded(schema: schema)
	}

	/// Copy pre-App-Group history into the shared store once. Skips ids
	/// already present, so it's idempotent and tolerates the extension having
	/// written a row first.
	private func migrateLegacyHistoryIfNeeded(schema: Schema) {
		guard AppGroupStore.needsMigration("history") else { return }
		AppGroupStore.markMigrated("history")
		guard let context,
		      let legacy = try? ModelContainer(
		      	for: schema,
		      	configurations: [AppGroupStore.legacyConfiguration("history", schema: schema)]
		      )
		else { return }
		let legacyContext = ModelContext(legacy)
		guard let rows = try? legacyContext.fetch(FetchDescriptor<HistoryPlaylist>()), !rows.isEmpty
		else { return }
		let existing = Set(((try? context.fetch(FetchDescriptor<HistoryPlaylist>())) ?? []).map(\.id))
		for row in rows where !existing.contains(row.id) {
			let copy = HistoryPlaylist(
				id: row.id,
				playedAt: row.playedAt,
				name: row.name,
				seedSongID: row.seedSongID,
				seedTitle: row.seedTitle,
				seedArtist: row.seedArtist
			)
			copy.feedbackRaw = row.feedbackRaw
			context.insert(copy)
			for song in row.songs.sorted(by: { $0.position < $1.position }) {
				let songCopy = HistorySong(
					songID: song.songID,
					title: song.title,
					artistName: song.artistName,
					albumTitle: song.albumTitle,
					position: song.position
				)
				songCopy.playlist = copy
				copy.songs.append(songCopy)
			}
		}
		try? context.save()
	}

	/// Record a play. If the most recent entry overlaps this runway by
	/// ≥`mergeOverlapThreshold` and was played inside `mergeWindow`, it's
	/// merged into that row instead (seed + song list refreshed, name
	/// phrase kept, `ft. <artist>` suffix updated).
	///
	/// Caveat: a merge replaces `songs`, so a song removed via swipe-block
	/// reappears if it's in the new runway. The block itself lives in
	/// `TransitionFeedbackStore` and still holds — only the visual cleanup
	/// is lost.
	func record(name: String, seed: SongSnapshot, runway: [SongSnapshot]) {
		guard !runway.isEmpty else { return }
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let now = Date()

		var latestDescriptor = FetchDescriptor<HistoryPlaylist>(
			sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
		)
		latestDescriptor.fetchLimit = 1
		if let latest = try? context.fetch(latestDescriptor).first,
		   now.timeIntervalSince(latest.playedAt) < Self.mergeWindow,
		   Self.overlapRatio(runway: runway, against: latest) >= Self.mergeOverlapThreshold
		{
			latest.playedAt = now
			latest.seedSongID = seed.id
			latest.seedTitle = seed.title
			latest.seedArtist = seed.artistName
			latest.name = Self.updateArtistInName(latest.name, newArtist: seed.artistName)

			// Cascade-delete still needs the array cleared explicitly to
			// drop old references before inserting new ones.
			for old in latest.songs {
				context.delete(old)
			}
			latest.songs.removeAll()
			for (i, song) in runway.enumerated() {
				let row = HistorySong(
					songID: song.id,
					title: song.title,
					artistName: song.artistName,
					albumTitle: song.albumTitle,
					position: i
				)
				row.playlist = latest
				latest.songs.append(row)
			}

			try? context.save()
			return
		}

		let entry = HistoryPlaylist(
			playedAt: now,
			name: name,
			seedSongID: seed.id,
			seedTitle: seed.title,
			seedArtist: seed.artistName
		)
		context.insert(entry)
		for (i, song) in runway.enumerated() {
			let row = HistorySong(
				songID: song.id,
				title: song.title,
				artistName: song.artistName,
				albumTitle: song.albumTitle,
				position: i
			)
			row.playlist = entry
			entry.songs.append(row)
		}

		// Prune past the soft cap.
		if let all = try? context.fetch(FetchDescriptor<HistoryPlaylist>(
			sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
		)), all.count > Self.maxEntries {
			for old in all[Self.maxEntries...] {
				context.delete(old)
			}
		}

		try? context.save()
	}

	func recent(limit: Int = 100) -> [HistoryEntrySnapshot] {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }

		var descriptor = FetchDescriptor<HistoryPlaylist>(
			sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
		)
		descriptor.fetchLimit = limit
		let rows = (try? context.fetch(descriptor)) ?? []
		return rows.map(HistoryEntrySnapshot.init)
	}

	/// A single entry by id, for App Intents entity resolution.
	func entry(id: UUID) -> HistoryEntrySnapshot? {
		do { try ensureLoaded() } catch { return nil }
		guard let context else { return nil }
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.id == id }
		)
		return (try? context.fetch(descriptor))?.first.map(HistoryEntrySnapshot.init)
	}

	func delete(id: UUID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.id == id }
		)
		if let row = try? context.fetch(descriptor).first {
			context.delete(row)
			try? context.save()
		}
	}

	/// Rename a stored entry. Empty values are allowed — `displayName`
	/// falls back to `seedTitle`.
	func rename(id: UUID, to newName: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.id == id }
		)
		if let row = try? context.fetch(descriptor).first {
			row.name = newName
			try? context.save()
		}
	}

	/// Persist run-level feedback. Setting `.none` clears the rating but
	/// not the "Bad Run" bulk-blocks — those are independent data.
	func setFeedback(_ feedback: HistoryFeedback, for id: UUID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.id == id }
		)
		if let row = try? context.fetch(descriptor).first {
			row.feedback = feedback
			try? context.save()
		}
	}

	/// Per-song most-recent play date inside the window (seed + every
	/// runway song). `GemScorer` uses it for a soft recency downrank:
	/// MusicKit's `Song.lastPlayedDate` lags `SystemMusicPlayer` plays,
	/// but our log is written synchronously in `play(from:)`.
	///
	/// Design mode also leans on this to avoid resurfacing songs from a
	/// just-generated playlist; rows are written at generation time, so a
	/// within-session window catches discarded designs.
	///
	/// Returns a dict, not a set, so callers can apply a proportional
	/// penalty — hard exclusion was too aggressive for small libraries.
	func recentPlays(within interval: TimeInterval) -> [String: Date] {
		do { try ensureLoaded() } catch { return [:] }
		guard let context else { return [:] }

		let cutoff = Date().addingTimeInterval(-interval)
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.playedAt >= cutoff }
		)
		let rows = (try? context.fetch(descriptor)) ?? []

		var result: [String: Date] = [:]
		for row in rows {
			Self.updateIfNewer(&result, row.seedSongID, row.playedAt)
			for song in row.songs {
				Self.updateIfNewer(&result, song.songID, row.playedAt)
			}
		}
		return result
	}

	private static func updateIfNewer(_ dict: inout [String: Date], _ id: String, _ date: Date) {
		if let existing = dict[id], existing >= date { return }
		dict[id] = date
	}

	/// Intersection-over-min-set overlap: 0.0 when nothing shared, 1.0
	/// when one is a subset of the other.
	private static func overlapRatio(runway: [SongSnapshot], against entry: HistoryPlaylist) -> Double {
		let newIDs = Set(runway.map(\.id))
		let oldIDs = Set(entry.songs.map(\.songID))
		guard !newIDs.isEmpty, !oldIDs.isEmpty else { return 0 }
		let intersection = newIDs.intersection(oldIDs).count
		let smaller = min(newIDs.count, oldIDs.count)
		return Double(intersection) / Double(smaller)
	}

	/// Swap the artist after the " ft. " marker, keeping the rest of the
	/// name. Leaves names without a ft. marker (older rows) untouched.
	private static func updateArtistInName(_ name: String, newArtist: String) -> String {
		guard let range = name.range(of: " ft. ") else { return name }
		let phrase = String(name[..<range.lowerBound])
		return "\(phrase) ft. \(newArtist)"
	}

	/// Remove a song from a history playlist (swipe-flag action). The pair
	/// block lives in `TransitionFeedbackStore`, so this only changes the
	/// displayed playlist; future walks still honor the block.
	func removeSong(songID: String, from entryID: UUID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		let descriptor = FetchDescriptor<HistoryPlaylist>(
			predicate: #Predicate { $0.id == entryID }
		)
		guard let entry = try? context.fetch(descriptor).first else { return }
		guard let target = entry.songs.first(where: { $0.songID == songID }) else { return }
		context.delete(target)
		try? context.save()
	}
}

/// Sendable snapshot of a `Song`, to avoid dragging MusicKit's
/// non-Sendable types across `HistoryStore`'s actor boundary.
struct SongSnapshot: Hashable {
	let id: String
	let title: String
	let artistName: String
	let albumTitle: String?

	init(id: String, title: String, artistName: String, albumTitle: String?) {
		self.id = id
		self.title = title
		self.artistName = artistName
		self.albumTitle = albumTitle
	}

	init(song: Song) {
		id = song.id.rawValue
		title = song.title
		artistName = song.artistName
		albumTitle = song.albumTitle
	}
}

extension Array where Element == SongSnapshot {
	/// Resolve snapshots back to live library `Song`s, preserving order and
	/// dropping any no longer in the user's library. Shared by the History
	/// "Save to library" button and the `SaveToLibrary` App Intent.
	func resolveLibrarySongs() async throws -> [Song] {
		let ids = map { MusicItemID($0.id) }
		guard !ids.isEmpty else { return [] }
		var request = MusicLibraryRequest<Song>()
		request.filter(matching: \.id, memberOf: ids)
		let response = try await request.response()
		let byID = Dictionary(uniqueKeysWithValues: response.items.map { ($0.id, $0) })
		return ids.compactMap { byID[$0] }
	}
}

/// Plain-value view of a stored `HistoryPlaylist`, handed out from the
/// actor so views needn't touch non-Sendable SwiftData model objects.
struct HistoryEntrySnapshot: Identifiable, Hashable {
	let id: UUID
	let playedAt: Date
	let name: String
	let feedback: HistoryFeedback
	let seedTitle: String
	let seedArtist: String
	let songs: [SongSnapshot]

	/// Falls back to the seed title for empty `name` (older rows), so they
	/// don't render as blank list items.
	var displayName: String {
		name.isEmpty ? seedTitle : name
	}

	init(_ entry: HistoryPlaylist) {
		id = entry.id
		playedAt = entry.playedAt
		name = entry.name
		feedback = entry.feedback
		seedTitle = entry.seedTitle
		seedArtist = entry.seedArtist
		songs = entry.songs
			.sorted { $0.position < $1.position }
			.map { SongSnapshot(
				id: $0.songID,
				title: $0.title,
				artistName: $0.artistName,
				albumTitle: $0.albumTitle
			) }
	}
}
