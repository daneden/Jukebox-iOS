//
//  EmbeddingProgress.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Observable projection of "how much of the current gem deck has been
//  embedded yet." Drives the toolbar progress indicator and its popover.
//  Source of truth is SwiftData (the SongEmbedding rows).

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

	/// 0…1, or 1 when no deck is tracked yet (so empty state isn't "0% of 0").
	var fraction: Double {
		guard totalCount > 0 else { return 1.0 }
		return Double(embeddedCount) / Double(totalCount)
	}

	var isComplete: Bool {
		totalCount > 0 && embeddedCount >= totalCount
	}

	/// Gates whether the toolbar indicator appears.
	var hasDeck: Bool {
		totalCount > 0
	}

	/// Re-initialise the tracker for a new deck. `existing` is song-ID raw
	/// values that already have cached embeddings, so a previously-embedded
	/// deck doesn't undercount.
	func setTracking(songIDs: [MusicItemID], existing: Set<String>) {
		let rawTracked = Set(songIDs.map(\.rawValue))
		tracked = rawTracked
		embedded = rawTracked.intersection(existing)
	}

	/// Marks a tracked song as finished — successful embed or a permanent
	/// failure the warmer gave up on. No-op for untracked songs.
	///
	/// Counting failures too: otherwise progress stalls at e.g. 298/300
	/// forever when a couple of songs can't resolve to a catalog preview.
	/// The warmer moves on after one failed attempt, so the counter mirrors that.
	func recordProcessed(_ id: MusicItemID) {
		guard tracked.contains(id.rawValue) else { return }
		embedded.insert(id.rawValue)
	}
}
