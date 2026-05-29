//
//  OriginalReleaseStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Actor over the SwiftData container of `SongOriginalDate` rows.
//  Cache-first lookup for the decade filter + walk-side era similarity,
//  populated by `OriginalReleaseResolver` during library warming.
//
//  Local-only (no CloudKit); reinstall rebuilds the cache under WiFi + power.

import Dispatch
import Foundation
import MusicKit
import SwiftData

actor OriginalReleaseStore {
	/// Bump when the resolver's strategy changes (e.g. starts consulting
	/// a new relationship). Old rows are treated as misses on read.
	static let currentModelVersion = 1

	static let shared = OriginalReleaseStore()

	/// Pinned `userInitiated` executor (as `EmbeddingStore`): the
	/// user-initiated decade filter and the utility warmer both touch the
	/// actor, and pinning avoids priority-inversion warnings.
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
		// Named so this store gets its own sqlite file. Multiple actors
		// opening one file with different schemas leaves whichever
		// container initialised first holding the tables; the rest hit
		// "no such table" at fetch time.
		let config = ModelConfiguration("originalDates", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

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

	/// "Already looked up?" lookup for the warmer. Includes `nil`-date
	/// rows — those were resolved to the library's own date, and skipping
	/// them avoids burning a redundant catalog request.
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

	/// Upsert. Pass `nil` for `date` when nothing earlier than the
	/// library's own date was found — recording it stops the warmer from
	/// repeating the lookup.
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
