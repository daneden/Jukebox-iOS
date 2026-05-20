//
//  GemDeckBuilder.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import MusicKit

/// Builds the "hidden gems" deck for Songs mode.
///
/// Strategy: fetch two complementary candidate pools from MusicKit
/// (nostalgia: highest playCount; discovery: oldest libraryAddedDate),
/// merge & dedupe, score with `GemScorer`, keep the top N, then shuffle
/// within that top-N so the user sees variety per session instead of the
/// same #1 every time.
///
/// Why two pools instead of scanning the whole library: a heavy user has
/// 5k–50k library songs. Paging the entire library on every Songs-tab
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

	/// Final-result API: consumes the stream and returns the last emission.
	/// Useful for callers that don't care about intermediate progress
	/// (e.g. the embedding spike).
	static func build(now: Date = Date()) async throws -> BuildResult {
		var last: BuildResult?
		for try await result in buildStreaming(now: now) {
			last = result
		}
		return last ?? BuildResult(deck: [], scannedCount: 0)
	}

	/// Streaming API: yields a partial deck as soon as the nostalgia pool
	/// returns (scored on nostalgia alone), then yields a final deck once
	/// the discovery pool joins. SongsView consumes this so the dial
	/// becomes interactive at roughly half the cold-launch wait — the
	/// final deck slides in via the lift-out transition when ready.
	///
	/// Why nostalgia-first rather than first-completed: both pools take
	/// similar time (both do a full-library sort + 1500-row hydrate), and
	/// the partial deck built on nostalgia alone skews to "songs you used
	/// to play a lot," which is a reasonable thing to land on while
	/// discovery is still arriving.
	static func buildStreaming(now: Date = Date()) -> AsyncThrowingStream<BuildResult, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let scorer = GemScorer(now: now)
					// Session-stable seed: partial and final share it so any
					// song present in both decks lands at the same dial index
					// in both yields. Reduces lift-out churn during the
					// partial → final swap to just the genuinely new entries.
					// Across cold starts, fresh seed → fresh ordering.
					let seed = UInt64.random(in: 0 ... UInt64.max)

					async let nostalgiaTask = fetchPool(sort: .playCount, ascending: false)
					async let discoveryTask = fetchPool(sort: .libraryAddedDate, ascending: true)

					let nostalgia = try await nostalgiaTask
					continuation.yield(rank(songs: nostalgia, scorer: scorer, seed: seed))

					let discovery = try await discoveryTask
					let union = dedupeUnion(nostalgia: nostalgia, discovery: discovery)
					continuation.yield(rank(songs: union, scorer: scorer, seed: seed))

					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private static func rank(songs: [Song], scorer: GemScorer, seed: UInt64) -> BuildResult {
		let ranked = scorer.scoreAndRank(songs)
		let top = ranked.prefix(deckSize).map(\.song)
		// Sort by hash(songID, seed) — each song has a stable per-session
		// "shuffle position" determined solely by its id, not by other
		// songs in the list. Same song lands at the same relative position
		// in partial and final.
		let deck = top.sorted { lhs, rhs in
			seededHash(lhs.id.rawValue, seed: seed) < seededHash(rhs.id.rawValue, seed: seed)
		}
		return BuildResult(deck: deck, scannedCount: songs.count)
	}

	private static func seededHash(_ key: String, seed: UInt64) -> UInt64 {
		var hasher = Hasher()
		hasher.combine(seed)
		hasher.combine(key)
		return UInt64(bitPattern: Int64(hasher.finalize()))
	}

	private static func dedupeUnion(nostalgia: [Song], discovery: [Song]) -> [Song] {
		var seen = Set<MusicItemID>()
		var union: [Song] = []
		union.reserveCapacity(nostalgia.count + discovery.count)
		for song in nostalgia where seen.insert(song.id).inserted {
			union.append(song)
		}
		for song in discovery where seen.insert(song.id).inserted {
			union.append(song)
		}
		return union
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
