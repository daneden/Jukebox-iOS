//
//  TransitionFeedbackStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Actor wrapper around the SwiftData container holding `BlockedTransition`
//  rows. The Songs walk reads the blocked pair keys at deck-build time and
//  refuses to place those songs adjacent.
//
//  Separate store from `HistoryStore` / `EmbeddingStore` so a schema change to
//  one doesn't drag the others along.

import Foundation
import SwiftData

actor TransitionFeedbackStore {
	static let shared = TransitionFeedbackStore()

	private var container: ModelContainer?
	private var context: ModelContext?

	/// Canonical pair key — symmetric so blocking "A→B" also blocks "B→A".
	static func pairKey(_ idA: String, _ idB: String) -> String {
		[idA, idB].sorted().joined(separator: "|")
	}

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([BlockedTransition.self])
		// Named so this store gets its own sqlite file — see `EmbeddingStore`.
		let config = ModelConfiguration("transitions", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	func block(_ idA: String, _ idB: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let key = Self.pairKey(idA, idB)
		let descriptor = FetchDescriptor<BlockedTransition>(
			predicate: #Predicate { $0.pairKey == key }
		)
		if (try? context.fetch(descriptor).first) != nil { return }

		let row = BlockedTransition(songIDA: idA, songIDB: idB)
		context.insert(row)
		try? context.save()
	}

	func unblock(_ idA: String, _ idB: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let key = Self.pairKey(idA, idB)
		let descriptor = FetchDescriptor<BlockedTransition>(
			predicate: #Predicate { $0.pairKey == key }
		)
		if let row = try? context.fetch(descriptor).first {
			context.delete(row)
			try? context.save()
		}
	}

	/// Snapshot of every blocked pair for `SongDeckWalk.walk(... blockedPairs:)`.
	func allBlockedPairs() -> Set<String> {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }
		let descriptor = FetchDescriptor<BlockedTransition>()
		let rows = (try? context.fetch(descriptor)) ?? []
		return Set(rows.map(\.pairKey))
	}
}
