//
//  EmbeddingProgress.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Observable counter for "how much of the current gem deck has been
//  embedded yet." Drives the toolbar progress indicator and its popover.
//
//  Source of truth lives in SwiftData (the SongEmbedding rows); this
//  type is a lightweight projection of "rows that exist for songs in
//  the deck we currently care about." It receives push notifications
//  from `EmbeddingStore.store(...)` and is re-initialised from
//  `SongsView.buildDeck` when a new deck lands.

import Foundation
import MusicKit
import Observation

@MainActor
@Observable
final class EmbeddingProgress {
	static let shared = EmbeddingProgress()

	private(set) var tracked: Set<String> = []
	private(set) var embedded: Set<String> = []

	var totalCount: Int {
		tracked.count
	}

	var embeddedCount: Int {
		embedded.count
	}

	var remainingCount: Int {
		max(0, totalCount - embeddedCount)
	}

	/// 0…1, or 1 when no deck is being tracked yet (so a fresh, empty
	/// state doesn't render as "0% of 0").
	var fraction: Double {
		guard totalCount > 0 else { return 1.0 }
		return Double(embeddedCount) / Double(totalCount)
	}

	var isComplete: Bool {
		totalCount > 0 && embeddedCount >= totalCount
	}

	/// True once `setTracking` has been called at least once for the
	/// current deck — gates whether the toolbar indicator appears.
	var hasDeck: Bool {
		totalCount > 0
	}

	/// Re-initialise the tracker for a new deck. `existing` is the set
	/// of song-ID raw values that already have cached embeddings, so we
	/// don't undercount when the user returns to a deck they previously
	/// embedded fully.
	func setTracking(songIDs: [MusicItemID], existing: Set<String>) {
		let rawTracked = Set(songIDs.map(\.rawValue))
		tracked = rawTracked
		embedded = rawTracked.intersection(existing)
	}

	/// Marks a tracked song as finished for this session — either a
	/// successful embed (called from `EmbeddingStore.store`) or a permanent
	/// failure the warmer gave up on (called from `GemDeckBuilder`'s
	/// `warmEmbeddings` after a `try?`). No-op for untracked songs (e.g.
	/// ad-hoc embeds from the spike).
	///
	/// **Why:** progress would otherwise stall at e.g. 298/300 forever when
	/// a couple of deck songs can't be resolved to a catalog preview
	/// (`noCatalogMatch`, `noPreview`, `downloadFailed`, …). Since the
	/// warmer already moves on after one failed attempt, the progress
	/// counter should mirror that.
	func recordProcessed(_ id: MusicItemID) {
		guard tracked.contains(id.rawValue) else { return }
		embedded.insert(id.rawValue)
	}
}
