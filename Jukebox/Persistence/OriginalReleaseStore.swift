//
//  OriginalReleaseStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Actor wrapper around the SwiftData container holding
//  `SongOriginalDate` rows. Cache-first lookup for the decade filter +
//  walk-side era similarity, populated opportunistically by
//  `OriginalReleaseResolver` via deck-warm and long-tail library
//  warming. Behaviour mirrors `EmbeddingStore`.
//
//  Local-only (no CloudKit). Reinstall loses the cache; the warmer
//  rebuilds it under WiFi + power.

import Dispatch
import Foundation
import MusicKit
import SwiftData

actor OriginalReleaseStore {
	/// Bump when the resolver's strategy changes (e.g. starts consulting
	/// a new relationship). Old rows are treated as misses on read.
	static let currentModelVersion = 1

	static let shared = OriginalReleaseStore()

	/// Pinned `userInitiated` executor for the same reason as
	/// `EmbeddingStore`: the decade filter (user-initiated) and the
	/// warmer (utility) both touch the actor, and without pinning the
	/// runtime flags priority inversions when a higher-priority waiter
	/// lands behind a lower-priority job.
	private nonisolated let queue = DispatchSerialQueue(
		label: "me.daneden.Jukebox.OriginalReleaseStore",
		qos: .userInitiated
	)
	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([SongOriginalDate.self])
		// Named so this store gets its own sqlite file rather than
		// fighting `EmbeddingStore`, `HistoryStore`, and
		// `TransitionFeedbackStore` over the default unnamed store.
		// Multiple actors opening the same file with different schemas
		// leaves whichever container initialised first holding the
		// tables; the others surface "no such table" errors at fetch
		// time.
		let config = ModelConfiguration("originalDates", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	/// Bulk lookup — single SwiftData fetch for all matching rows.
	/// Returns only songs with a non-nil cached date; the read-side
	/// fallback (`?? song.releaseDate`) handles the rest.
	func originalDates(for songIDs: [MusicItemID]) -> [MusicItemID: Date] {
		do { try ensureLoaded() } catch { return [:] }
		guard let context else { return [:] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongOriginalDate>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [:] }

		var result: [MusicItemID: Date] = [:]
		result.reserveCapacity(rows.count)
		for row in rows {
			if let date = row.originalDate {
				result[MusicItemID(row.songID)] = date
			}
		}
		return result
	}

	/// "Have we already looked these up?" lookup for the warmer —
	/// includes rows with `originalDate == nil` because we still
	/// recorded the resolution. Skipping them avoids burning a catalog
	/// request on songs whose original we already determined to be
	/// the library's own date.
	func resolvedIDs(for songIDs: [MusicItemID]) -> Set<String> {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongOriginalDate>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [] }
		return Set(rows.map(\.songID))
	}

	/// Upsert. Pass `nil` for `date` when the resolver looked but found
	/// nothing earlier than the library's own date — recording the
	/// resolution stops the warmer from repeating the lookup.
	func store(_ date: Date?, for songID: MusicItemID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let descriptor = FetchDescriptor<SongOriginalDate>(
			predicate: #Predicate { $0.songID == id }
		)
		if let existing = try? context.fetch(descriptor).first {
			existing.originalDate = date
			existing.modelVersion = Self.currentModelVersion
			existing.resolvedAt = Date()
		} else {
			let new = SongOriginalDate(
				songID: id,
				originalDate: date,
				modelVersion: Self.currentModelVersion,
				resolvedAt: Date()
			)
			context.insert(new)
		}
		try? context.save()
	}
}
