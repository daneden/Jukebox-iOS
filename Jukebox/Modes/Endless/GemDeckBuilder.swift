//
//  GemDeckBuilder.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import MusicKit

/// Builds the "hidden gems" deck for Endless mode.
///
/// Strategy: fetch two complementary candidate pools from MusicKit
/// (nostalgia: highest playCount; discovery: oldest libraryAddedDate),
/// merge & dedupe, score with `GemScorer`, keep the top N, then shuffle
/// within that top-N so the user sees variety per session instead of the
/// same #1 every time.
///
/// Why two pools instead of scanning the whole library: a heavy user has
/// 5k–50k library songs. Paging the entire library on every Endless-tab
/// appearance is wasteful (and user has flagged unbounded scans before).
/// The cost we accept: a song that's middling on *both* axes can miss
/// both pools and never appear. Worth it.
enum GemDeckBuilder {
	/// Per-pool fetch limit. ~1500 each gives a healthy union (~2-3k after
	/// dedupe) for scoring without scanning the whole library.
	static let poolSize = 1500
	/// Top-N kept after scoring. The deck is then shuffled so the actual
	/// playback order varies per session.
	static let deckSize = 300

	struct BuildResult {
		let deck: [Song]
		let scannedCount: Int
	}

	static func build(now: Date = Date()) async throws -> BuildResult {
		let scorer = GemScorer(now: now)

		async let nostalgiaPool = fetchPool(sort: .playCount, ascending: false)
		async let discoveryPool = fetchPool(sort: .libraryAddedDate, ascending: true)

		let (nostalgia, discovery) = try await (nostalgiaPool, discoveryPool)

		// Dedupe by MusicItemID — same song often appears in both pools.
		var seen = Set<MusicItemID>()
		var union: [Song] = []
		union.reserveCapacity(nostalgia.count + discovery.count)
		for song in nostalgia where seen.insert(song.id).inserted {
			union.append(song)
		}
		for song in discovery where seen.insert(song.id).inserted {
			union.append(song)
		}

		let ranked = scorer.scoreAndRank(union)
		let top = ranked.prefix(deckSize).map(\.song)
		// Shuffle within the top-N — top-ranked deterministic order would
		// hand the same song to the user every time they open the tab.
		let deck = top.shuffled()

		return BuildResult(deck: deck, scannedCount: union.count)
	}

	/// Which axis to sort the candidate pool on. One sort key per
	/// `MusicLibraryRequest`, so we run two requests in parallel.
	enum PoolSort {
		case playCount
		case libraryAddedDate
	}

	private static func fetchPool(sort: PoolSort, ascending: Bool) async throws -> [Song] {
		var request = MusicLibraryRequest<Song>()
		switch sort {
		case .playCount:
			request.sort(by: \.playCount, ascending: ascending)
		case .libraryAddedDate:
			request.sort(by: \.libraryAddedDate, ascending: ascending)
		}
		request.limit = poolSize
		let response = try await request.response()
		return Array(response.items)
	}
}
