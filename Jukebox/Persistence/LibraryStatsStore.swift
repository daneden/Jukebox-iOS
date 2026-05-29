//
//  LibraryStatsStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Actor over the SwiftData container holding the single
//  `LibraryStatsSnapshot` row. `load()` paints the last result instantly;
//  `save()` stores a background recompute.
//
//  Local-only (no CloudKit); reinstall recomputes on first open.

import Dispatch
import Foundation
import SwiftData

actor LibraryStatsStore {
	/// Bump when the payload shape or classification semantics change, so an
	/// older snapshot is recomputed rather than shown stale-and-wrong.
	static let currentModelVersion = 1

	private static let rowKey = "library"

	static let shared = LibraryStatsStore()

	/// Pinned `userInitiated` executor (as other stores): the user-initiated
	/// overview and the refresh loop both touch the actor, and pinning avoids
	/// priority-inversion warnings.
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
		// Named so this store gets its own sqlite file, not the shared
		// default — see `OriginalReleaseStore`.
		let config = ModelConfiguration("libraryStats", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	/// The last persisted snapshot, or nil if none exists or it predates the
	/// current payload version.
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
