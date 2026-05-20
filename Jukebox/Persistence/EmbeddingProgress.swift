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

	/// Called from `EmbeddingStore.store` whenever a row is upserted.
	/// No-op for songs we're not currently tracking (e.g. the embedding
	/// spike embedding ad-hoc samples).
	func recordEmbedded(_ id: MusicItemID) {
		guard tracked.contains(id.rawValue) else { return }
		embedded.insert(id.rawValue)
	}
}
