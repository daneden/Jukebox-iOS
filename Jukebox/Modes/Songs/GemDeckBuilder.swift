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
	/// Multiplier on `deckSize` used as the candidate slice when
	/// `wideSample: true`. Larger = more variety in super-shuffle, at
	/// the cost of letting lower-scored gems into the deck.
	static let wideSampleMultiplier = 2

	static func buildStreaming(
		now: Date = Date(),
		wideSample: Bool = false
	) -> AsyncThrowingStream<BuildResult, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					// Our own recent-play log supplements MusicKit's
					// `Song.lastPlayedDate` for the recency downrank —
					// that field lags or outright fails to update for
					// `SystemMusicPlayer` plays on library-only items,
					// so songs we know we just queued would otherwise
					// resurface as high-ranked seeds. Soft penalty (not
					// hard exclude) so smaller libraries don't run out
					// of candidates inside the 14-day window.
					let recentPlays = await HistoryStore.shared.recentPlays(within: 14)
					let scorer = GemScorer(
						now: now,
						recentPlays: recentPlays
					)
					// Session-stable seed: partial and final share it so the
					// walk starts in the same neighborhood for both yields,
					// reducing churn across the partial → final swap.
					let seed = UInt64.random(in: 0 ... UInt64.max)

					async let nostalgiaTask = fetchPool(sort: .playCount, ascending: false)
					async let discoveryTask = fetchPool(sort: .libraryAddedDate, ascending: true)

					let nostalgia = try await nostalgiaTask
					continuation.yield(await rank(
						songs: nostalgia,
						scorer: scorer,
						seed: seed,
						wideSample: wideSample
					))

					let discovery = try await discoveryTask
					let union = dedupeUnion(nostalgia: nostalgia, discovery: discovery)
					let final = await rank(
						songs: union,
						scorer: scorer,
						seed: seed,
						wideSample: wideSample
					)
					continuation.yield(final)

					continuation.finish()

					// After the final deck lands, kick off background
					// embedding work for any songs in it that don't have a
					// cached embedding yet. This converges the next
					// session's walk on real audio similarity rather than
					// the genre-Jaccard fallback. Fire-and-forget — survives
					// or doesn't survive the buildStreaming task's lifetime
					// independently.
					warmEmbeddings(for: final.deck)
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Cap on how many tracks from a single artist enter the deck. The
	/// walk's artist-lookback (≤2) only prevents adjacency; if the
	/// candidate pool itself is e.g. 30 Zomby tracks (heavy nostalgia
	/// playCount), the walk runs out of non-Zomby candidates and
	/// relaxes, clumping them anyway. Capping at the deck stage means
	/// the walk always has enough variety on hand.
	static let perArtistCap = 8

	/// Cap on tracks from a single album. The user reported "almost an
	/// entire Zomby album" in one deck — heavy library skew was filling
	/// the deck with full-album-listings. 3 lets distinctive albums
	/// still surface multiple tracks without dominating the list.
	static let perAlbumCap = 3

	private static func rank(
		songs: [Song],
		scorer: GemScorer,
		seed: UInt64,
		wideSample: Bool = false
	) async -> BuildResult {
		let ranked = scorer.scoreAndRank(songs)
		let top: [Song]
		if wideSample {
			// Super-shuffle: widen the slice and sample down to deckSize,
			// so the deck genuinely turns over rather than just re-walking
			// the same top-300 in a different order. Shuffle uses the
			// system RNG (fresh per call) — each press gives a different
			// sample even though scoring is deterministic.
			//
			// Caps applied to the widened pool first so the resulting
			// shuffled deck still respects per-artist/album limits.
			let wideCount = min(deckSize * wideSampleMultiplier, ranked.count)
			let widePool = capPerArtistAndAlbum(
				ranked.prefix(wideCount).map(\.song),
				limit: deckSize * wideSampleMultiplier
			)
			top = Array(widePool.shuffled().prefix(deckSize))
		} else {
			top = capPerArtistAndAlbum(ranked.map(\.song), limit: deckSize)
		}
		// Bulk-load embeddings for the top-N; the walk uses them where
		// available and falls back to genre Jaccard for songs that
		// haven't been embedded yet.
		let embeddings = await EmbeddingStore.shared.embeddings(for: top.map(\.id))
		// Pull the user's blocked-pair feedback so the walk avoids
		// recreating transitions they've explicitly rejected.
		let blockedPairs = await TransitionFeedbackStore.shared.allBlockedPairs()
		let deck = SongDeckWalk.walk(
			songs: top,
			embeddings: embeddings,
			blockedPairs: blockedPairs,
			seed: seed
		)
		return BuildResult(deck: deck, scannedCount: songs.count)
	}

	/// Walks the score-sorted candidate list and keeps each song unless
	/// its artist or album has already hit the cap. Stops at `limit` or
	/// when the pool is exhausted — whichever comes first. An empty
	/// `albumTitle` skips the album cap (don't lump all metadata-less
	/// tracks under one "unknown album" bucket).
	private static func capPerArtistAndAlbum(_ ordered: [Song], limit: Int) -> [Song] {
		var perArtist: [String: Int] = [:]
		var perAlbum: [String: Int] = [:]
		var result: [Song] = []
		result.reserveCapacity(limit)

		for song in ordered {
			if result.count >= limit { break }

			let artist = song.artistName
			if perArtist[artist, default: 0] >= perArtistCap { continue }

			let album = song.albumTitle ?? ""
			if !album.isEmpty, perAlbum[album, default: 0] >= perAlbumCap {
				continue
			}

			result.append(song)
			perArtist[artist, default: 0] += 1
			if !album.isEmpty {
				perAlbum[album, default: 0] += 1
			}
		}

		return result
	}

	private static func warmEmbeddings(for deck: [Song]) {
		Task.detached(priority: .background) {
			for song in deck {
				if await EmbeddingStore.shared.embedding(for: song.id) != nil {
					continue
				}
				_ = try? await AudioEmbeddingService.embed(song: song)
				// Small breath between requests so we don't hammer the
				// network or the user's battery in one burst.
				try? await Task.sleep(for: .milliseconds(200))
			}
		}
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
