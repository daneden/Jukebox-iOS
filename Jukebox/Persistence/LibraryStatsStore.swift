//
//  LibraryStatsStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Actor wrapper around the SwiftData container holding the single
//  `LibraryStatsSnapshot` row. Lets the Library Overview sheet paint the
//  last computed `LibraryStats` instantly (read `load()`) while a fresh
//  recompute runs in the background (`LibraryStatsBuilder.refresh()` →
//  `save()`). Behaviour mirrors the per-song stores.
//
//  Local-only (no CloudKit). Reinstall loses the snapshot; the first open
//  recomputes it once. The expensive inputs aren't cached here — see
//  `LibraryStatsSnapshot`.

import Dispatch
import Foundation
import SwiftData

actor LibraryStatsStore {
	/// Bump when the persisted payload shape OR the classification semantics
	/// change (centroid bundle, scoring) so a snapshot from an older build is
	/// treated as a miss and recomputed rather than shown stale-and-wrong.
	static let currentModelVersion = 1

	/// Single-row key — the snapshot is whole-library, not per-song.
	private static let rowKey = "library"

	static let shared = LibraryStatsStore()

	/// Pinned `userInitiated` executor, same rationale as the other stores:
	/// the overview (user-initiated) and the eager prime / refresh loop both
	/// touch the actor, and pinning keeps the runtime from flagging priority
	/// inversions.
	private nonisolated let queue = DispatchSerialQueue(
		label: "me.daneden.Jukebox.LibraryStatsStore",
		qos: .userInitiated
	)
	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([LibraryStatsSnapshot.self])
		// Named so this store gets its own sqlite file rather than fighting
		// the other stores over the default unnamed store.
		let config = ModelConfiguration("libraryStats", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	/// The last persisted snapshot, or nil if none exists or it predates the
	/// current payload version (treated as a miss, recomputed on next refresh).
	func load() -> LibraryStats? {
		do { try ensureLoaded() } catch { return nil }
		guard let context else { return nil }

		let version = Self.currentModelVersion
		let key = Self.rowKey
		let descriptor = FetchDescriptor<LibraryStatsSnapshot>(
			predicate: #Predicate { $0.key == key && $0.modelVersion == version }
		)
		guard let row = try? context.fetch(descriptor).first else { return nil }
		return try? JSONDecoder().decode(LibraryStats.self, from: row.payload)
	}

	/// Upsert the single snapshot row. No-op if the stats fail to encode.
	func save(_ stats: LibraryStats) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }
		guard let payload = try? JSONEncoder().encode(stats) else { return }

		let key = Self.rowKey
		let descriptor = FetchDescriptor<LibraryStatsSnapshot>(
			predicate: #Predicate { $0.key == key }
		)
		if let existing = try? context.fetch(descriptor).first {
			existing.payload = payload
			existing.computedAt = Date()
			existing.modelVersion = Self.currentModelVersion
			existing.unionCount = stats.analysisPool.total
			existing.embeddedCount = stats.analysisPool.embedded
		} else {
			context.insert(LibraryStatsSnapshot(
				key: key,
				payload: payload,
				computedAt: Date(),
				modelVersion: Self.currentModelVersion,
				unionCount: stats.analysisPool.total,
				embeddedCount: stats.analysisPool.embedded
			))
		}
		try? context.save()
	}
}
