//
//  HistoryStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Actor wrapper around the SwiftData container holding `HistoryPlaylist`
//  rows. Records each Songs-mode play as a snapshotted runway so the
//  user can revisit a session's similarity walk later even though the
//  live deck reshuffles every cold launch.
//
//  Local-only (no CloudKit). Re-installing the app loses history —
//  acceptable for a single-device personal tool.

import Foundation
import MusicKit
import SwiftData

actor HistoryStore {
	static let shared = HistoryStore()

	/// Soft cap on stored entries; older rows are pruned on every insert.
	/// Generous because each row is ~20 short strings — pennies on disk.
	static let maxEntries = 200

	/// Window for treating a new play as a continuation of the most
	/// recent entry. Tuned long enough to catch a real listening
	/// session of flitting between seeds in the same deck, short enough
	/// to not glue a current play to one from this morning.
	static let mergeWindow: TimeInterval = 15 * 60

	/// Minimum overlap (intersection over min set size) for two runways
	/// to count as "the same session." Picking adjacent seeds in the
	/// same deck overlaps ~95%; a wholly different deck (post-shuffle)
	/// drops near zero. 50% cleanly separates "different starting point,
	/// same deck" from "different deck altogether."
	static let mergeOverlapThreshold = 0.5

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([HistoryPlaylist.self, HistorySong.self])
		// Named so this store gets its own sqlite file — see
		// `EmbeddingStore.ensureLoaded` for the full rationale.
		let config = ModelConfiguration("history", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	/// Record a play. `name` is the human-facing label for the run
	/// (typically `PlaylistNamer.suggestedName(seedArtist:)`); `seed` is
	/// what the user landed on; `runway` is the ordered slice of the
	/// deck that was actually queued for playback.
	///
	/// If the most recent entry shares ≥`mergeOverlapThreshold` of its
	/// songs with this runway and was played inside `mergeWindow`, the
	/// new play is treated as a continuation of that session — same
	/// row, refreshed seed metadata and song list, name's phrase
	/// preserved but `ft. <artist>` suffix updated to match the new
	/// seed. Subsumes the prior same-seed-within-30s special case
	/// (which is just the 100%-overlap point of the same idea).
	///
	/// Caveat: a merge replaces `songs`, so a song the user previously
	/// removed via swipe-block reappears if it's in the new runway.
	/// The block itself lives in `TransitionFeedbackStore` and is
	/// unaffected — future deck builds still honor it — only the
	/// retrospective visual cleanup is lost.
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

			// Replace song rows. SwiftData cascade-deletes through the
			// inverse relationship, but we still need to clear the array
			// explicitly to drop the old references before inserting the
			// new ones.
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

		// Prune past the soft cap. One fetch is cheaper than a count + a
		// second fetch, and we're touching tiny numbers (≤201) here.
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

	/// Update the whimsical display name on a stored entry. Empty values
	/// are allowed — the row's `displayName` accessor falls back to
	/// `seedTitle` for those, so an emptied name doesn't render as a
	/// blank list item.
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

	/// Persist run-level feedback. Setting `.none` clears a prior
	/// rating; the bulk-blocked transitions from a prior "Bad Run"
	/// rating intentionally persist regardless — those are independent
	/// data, not derived from the feedback state.
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

	/// Per-song most-recent play date inside the window — both the
	/// explicit seed and every queued runway song. Used by `GemScorer`
	/// for a soft recency downrank: MusicKit's `Song.lastPlayedDate`
	/// lags or never updates for `SystemMusicPlayer` plays, so on its
	/// own it lets recently-played songs slip back in as seeds. Our log
	/// is written synchronously in `play(from:)` so it has no lag.
	///
	/// Design mode also leans on this to avoid resurfacing songs from a
	/// just-generated playlist when the user iterates on the curve.
	/// `record(name:seed:runway:)` writes a row at generation time
	/// (before playback), so a within-session window catches discarded
	/// designs without needing extra bookkeeping.
	///
	/// We return a dict rather than a set so callers can compute a
	/// proportional penalty (heavy for plays today, recovering to no
	/// penalty at the cutoff). Hard exclusion was too aggressive for
	/// small libraries.
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

	/// Intersection-over-min-set overlap between a new runway and the
	/// stored entry's song list. 0.0 when nothing shared, 1.0 when one
	/// is a subset of the other.
	private static func overlapRatio(runway: [SongSnapshot], against entry: HistoryPlaylist) -> Double {
		let newIDs = Set(runway.map(\.id))
		let oldIDs = Set(entry.songs.map(\.songID))
		guard !newIDs.isEmpty, !oldIDs.isEmpty else { return 0 }
		let intersection = newIDs.intersection(oldIDs).count
		let smaller = min(newIDs.count, oldIDs.count)
		return Double(intersection) / Double(smaller)
	}

	/// Swap the artist after the " ft. " marker without re-rolling the
	/// rest of the name, so a session that started as "Slow burn ft.
	/// Aphex Twin" becomes "Slow burn ft. Caroline Polachek" rather
	/// than churning to a wholly new phrase. If the existing name
	/// doesn't carry a ft. marker (older rows pre-feature), leave it.
	private static func updateArtistInName(_ name: String, newArtist: String) -> String {
		guard let range = name.range(of: " ft. ") else { return name }
		let phrase = String(name[..<range.lowerBound])
		return "\(phrase) ft. \(newArtist)"
	}

	/// Remove a song from a history playlist. Used by the swipe-flag
	/// action in the detail view — the pair block lives separately in
	/// `TransitionFeedbackStore`, so removing the row here only changes
	/// what the user sees in this run's playlist; future walks still
	/// honor the block.
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

/// Sendable, Identifiable snapshot used to hand a `Song` (or any
/// `MusicItem`) over to `HistoryStore` without dragging MusicKit's
/// non-Sendable types across actor boundaries.
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

/// Plain-value view of a stored `HistoryPlaylist`. We hand these out from
/// the actor so views don't have to touch SwiftData model objects
/// (which aren't Sendable and would otherwise pin the view to the
/// store's isolation domain).
struct HistoryEntrySnapshot: Identifiable, Hashable {
	let id: UUID
	let playedAt: Date
	let name: String
	let feedback: HistoryFeedback
	let seedTitle: String
	let seedArtist: String
	let songs: [SongSnapshot]

	/// Display-safe label. Empty `name` happens for rows persisted
	/// before the column existed — fall back to the seed song title so
	/// older history rows don't render as blank list items.
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
