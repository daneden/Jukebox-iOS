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
/// Strategy: fetch three complementary candidate pools from MusicKit
/// (nostalgia: highest playCount; discovery: oldest libraryAddedDate;
/// freshness: newest libraryAddedDate), merge & dedupe, score with
/// `GemScorer`, keep the top N, then shuffle within that top-N so the
/// user sees variety per session instead of the same #1 every time.
///
/// Why three pools instead of scanning the whole library: a heavy user
/// has 5k–50k library songs. Paging the entire library on every
/// Songs-tab appearance is wasteful (and user has flagged unbounded
/// scans before). The cost we accept: a song that's middling on *all
/// three* axes can miss every pool and never appear. Worth it.
enum GemDeckBuilder {
	/// Baseline per-pool fetch limit when no walk filters are active.
	/// 1000 each gives a healthy three-pool union (~2-2.5k after
	/// dedupe) for scoring without scanning the whole library. Down
	/// from 1500 with two pools: with three pools the previous size
	/// pulled ~50% more MusicKit hydration than needed, and shuffle
	/// times stretched well past the user's tolerance. When the user
	/// narrows the pool via energy/decade filters, `poolSize(for:)`
	/// scales this up so the post-filter candidate set has enough
	/// material to score and walk against.
	static let basePoolSize = 1000
	/// Hard ceiling on a single pool fetch even with the most restrictive
	/// filters active. Set to 4× the baseline — much higher and we start
	/// approaching a full-library scan for heavy users (50k libraries),
	/// which past incidents have flagged as wasteful.
	static let maxPoolSize = 6000
	/// Top-N kept after scoring. The deck is then shuffled so the actual
	/// playback order varies per session.
	static let deckSize = 300

	/// Per-pool fetch limit adapted to the active filters. MusicKit can't
	/// range-filter on releaseDate and the energy classifier needs an
	/// unfiltered pool to centroid-score against, so both filters must
	/// run client-side post-fetch — but with a 1500-cap fetch a strict
	/// "1960s Glacial" query can collapse the candidate set to a
	/// handful of songs. Growing the fetch when filters narrow the pool
	/// pushes the filter as high as we can practically apply it: same
	/// MusicLibraryRequest, just with more raw material so the filter
	/// has more to bite into.
	///
	/// Multipliers compound, capped at `maxPoolSize`:
	///  - energy != .any        → ×2
	///  - decade range narrow   → ×3 (span ≤ 30 years, i.e. ≤ 3 decades)
	///  - decade range bounded  → ×2 (4+ decades but not the full range)
	static func poolSize(for controls: WalkControls) -> Int {
		var multiplier = 1
		if controls.energy != .any { multiplier *= 2 }
		if !controls.decadeRange.isUnbounded {
			let span = controls.decadeRange.upper - controls.decadeRange.lower
			multiplier *= (span <= 30 ? 3 : 2)
		}
		return min(basePoolSize * multiplier, maxPoolSize)
	}

	struct BuildResult {
		let deck: [Song]
		let scannedCount: Int
		/// Min/max release decades from the *unfiltered* candidate pool.
		/// Used by the walk-controls range slider so its thumbs only
		/// travel decades that actually exist in the user's library.
		/// Nil when the pool is empty or no candidate has a releaseDate.
		let libraryDecadeBounds: ClosedRange<Int>?
	}

	/// Final-result API: consumes the stream and returns the last emission.
	/// Useful for callers that don't care about intermediate progress
	/// (e.g. the embedding spike).
	static func build(now: Date = Date()) async throws -> BuildResult {
		var last: BuildResult?
		for try await result in buildStreaming(now: now) {
			last = result
		}
		return last ?? BuildResult(deck: [], scannedCount: 0, libraryDecadeBounds: nil)
	}

	/// Builds the deck end-to-end: all three pools fetched in parallel,
	/// deduped, scored, capped, and walk-ordered. Yields exactly once
	/// with the finished deck. (Earlier versions yielded a nostalgia-
	/// only partial before the full union arrived, to make the dial
	/// interactive sooner on cold launch. The visible swap when the
	/// final landed was jarring — particularly once the freshness pool
	/// joined and the three-pool score normalisation diverged from the
	/// nostalgia-only one — so the partial yield was removed and the
	/// dial now waits behind the loading overlay for the full deck.)
	///
	/// Wrapped in `AsyncThrowingStream` rather than `async throws` so
	/// `onTermination` can cancel the underlying fetch task when the
	/// caller bails (the previous streaming consumer relied on this and
	/// the cancellation hook is still useful even with a single yield).
	/// Multiplier on `deckSize` used as the candidate slice when
	/// `wideSample: true`. Larger = more variety in super-shuffle, at
	/// the cost of letting lower-scored gems into the deck.
	static let wideSampleMultiplier = 2

	static func buildStreaming(
		now: Date = Date(),
		wideSample: Bool = false,
		controls: WalkControls = .default,
		avoidDecade: Int? = nil,
		avoidArtist: String? = nil
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
					let recentPlays = await HistoryStore.shared.recentPlays(within: 14 * 86400)
					let scorer = GemScorer(
						now: now,
						recentPlays: recentPlays
					)
					let seed = UInt64.random(in: 0 ... UInt64.max)

					let limit = poolSize(for: controls)
					async let nostalgiaTask = fetchPool(sort: .playCount, ascending: false, limit: limit)
					async let discoveryTask = fetchPool(sort: .libraryAddedDate, ascending: true, limit: limit)
					async let freshnessTask = fetchPool(sort: .libraryAddedDate, ascending: false, limit: limit)
					// Targeted slice for the requested band — fixes the
					// case where a mellow-leaning library would otherwise
					// post-filter the three base pools to almost nothing
					// when the user asks for Intense or Energetic. No-ops
					// when the filter is `.any`.
					async let bandSliceTask = fetchOptionalGenreSlice(for: controls.energy)

					let nostalgia = try await nostalgiaTask
					let discovery = try await discoveryTask
					let freshness = try await freshnessTask
					let bandSlice = await bandSliceTask
					let union = dedupeUnion(nostalgia, discovery, freshness, bandSlice)
					let final = await rank(
						songs: union,
						scorer: scorer,
						seed: seed,
						controls: controls,
						wideSample: wideSample,
						avoidDecade: avoidDecade,
						avoidArtist: avoidArtist
					)
					continuation.yield(final)

					continuation.finish()

					// After the final deck lands, kick off background
					// embedding work for any songs in it that don't have a
					// cached embedding yet. This converges the next
					// session's walk on real audio similarity rather than
					// the genre-similarity fallback. Fire-and-forget — survives
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

	/// Per-band fetch limit for the genre-keyword slice fetched
	/// alongside the three base pools when the user's walk filter
	/// targets a non-`.any` energy band. The base pools are sorted by
	/// playCount / libraryAddedDate, which inherit whatever bias the
	/// user's listening habits carry — a strictly mellow listener
	/// never sees their long-tail intense tracks surface through those
	/// alone. A targeted `filter(text:)` slice keyed off the selected
	/// band guarantees the post-classifier set has something to walk.
	static let bandSliceLimit = 500

	/// Most-distinctive genre keyword per band. Each band's
	/// `genreKeywords` array carries broader-coverage terms (e.g.
	/// "pop"/"rock") that would over-fetch into the wrong bucket; this
	/// picks the narrowest term that still has realistic library
	/// coverage. Mirrors `DesignedPlaylistBuilder.primarySliceKeyword`
	/// — duplicated rather than shared so each builder owns its own
	/// filtering policy.
	private static let primarySliceKeyword: [EnergyBand: String] = [
		.glacial: "ambient",
		.mellow: "soul",
		.energetic: "dance",
		.intense: "metal",
	]

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
		controls: WalkControls = .default,
		wideSample: Bool = false,
		avoidDecade: Int? = nil,
		avoidArtist: String? = nil
	) async -> BuildResult {
		// Library decade bounds from the *unfiltered* pool — surfaced so
		// the popover's range slider knows which decades actually exist
		// in the library. Calculated once here; the filter steps below
		// don't change the answer.
		let libraryDecadeBounds: ClosedRange<Int>? = {
			let decades = songs.compactMap(\.releaseDecade)
			guard let lo = decades.min(), let hi = decades.max() else { return nil }
			return lo ... hi
		}()

		// When energy filtering is active we need embeddings for the
		// whole input pool (the centroid classifier scores everything),
		// not just the eventual top-300. For the "Any" band we defer the
		// embedding fetch to after `top` is picked — the current pre-
		// classifier behaviour — to avoid loading ~3000 vectors when we
		// don't need them. The 'top-only' path below short-circuits this
		// branch.
		var poolEmbeddings: [MusicItemID: [Float]]?
		if controls.energy != .any {
			poolEmbeddings = await EmbeddingStore.shared.embeddings(for: songs.map(\.id))
		}

		// Energy: centroid-based refinement first; if there aren't
		// enough anchors with cached embeddings the classifier returns
		// nil and we fall through to the keyword filter; if *that* is
		// empty we fall through to the unfiltered pool. Soft-fail at
		// every step so a misconfigured band can't produce a blank deck.
		let energyPool: [Song]
		if controls.energy == .any {
			energyPool = songs
		} else if let emb = poolEmbeddings,
		          let centroidFiltered = EnergyClassifier.filter(songs, band: controls.energy, embeddings: emb),
		          !centroidFiltered.isEmpty
		{
			energyPool = centroidFiltered
		} else if let keywordFiltered = filterByEnergy(songs, energy: controls.energy),
		          !keywordFiltered.isEmpty
		{
			energyPool = keywordFiltered
		} else {
			energyPool = songs
		}

		// Decade range: hard filter on candidate releaseDecade. Songs
		// without a release date pass through (don't punish missing
		// metadata). Skip the filter when the range covers everything
		// (default); soft-fall-back to the un-decade-filtered pool if
		// the user's range matches nothing.
		let pool: [Song]
		if controls.decadeRange.isUnbounded {
			pool = energyPool
		} else {
			let decadeFiltered = energyPool.filter { song in
				guard let decade = song.releaseDecade else { return true }
				return controls.decadeRange.contains(decade)
			}
			pool = decadeFiltered.isEmpty ? energyPool : decadeFiltered
		}

		let ranked = scorer.scoreAndRank(pool)
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
		// Use the pool-wide embeddings if we already loaded them for the
		// classifier; otherwise fetch just the top-N for the walk.
		let embeddings: [MusicItemID: [Float]]
		if let emb = poolEmbeddings {
			let topIDs = Set(top.map(\.id))
			embeddings = emb.filter { topIDs.contains($0.key) }
		} else {
			embeddings = await EmbeddingStore.shared.embeddings(for: top.map(\.id))
		}
		// BPM data isn't pool-wide cached (we don't use it for
		// energy classification), so always fetch fresh for the
		// top-N. Returns only songs with a non-nil BPM; the walk's
		// similarity blend gates on per-pair coverage.
		let bpms = await EmbeddingStore.shared.bpms(for: top.map(\.id))
		// Pull the user's blocked-pair feedback so the walk avoids
		// recreating transitions they've explicitly rejected.
		let blockedPairs = await TransitionFeedbackStore.shared.allBlockedPairs()
		let deck = SongDeckWalk.walk(
			songs: top,
			embeddings: embeddings,
			bpms: bpms,
			blockedPairs: blockedPairs,
			seed: seed,
			controls: controls,
			avoidDecade: avoidDecade,
			avoidArtist: avoidArtist
		)
		return BuildResult(
			deck: deck,
			scannedCount: songs.count,
			libraryDecadeBounds: libraryDecadeBounds
		)
	}

	/// Returns nil when the band imposes no filter; otherwise returns
	/// the subset of `songs` whose `genreNames` contain (case-insensitive
	/// substring) any of the band's keywords.
	private static func filterByEnergy(_ songs: [Song], energy: EnergyBand) -> [Song]? {
		guard let keywords = energy.genreKeywords else { return nil }
		let lowered = keywords.map { $0.lowercased() }
		return songs.filter { song in
			song.genreNames.contains { genre in
				let g = genre.lowercased()
				return lowered.contains(where: g.contains)
			}
		}
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
		// `.utility` not `.background` — narrows the QoS gap to the
		// user-initiated walk reads from the same actor so the runtime
		// doesn't flag a priority inversion when a walk fetch lands
		// behind us.
		Task.detached(priority: .utility) {
			// One bulk fetch instead of 300 per-song actor hops, so the
			// walk's `embeddings(for:)` isn't stuck behind hundreds of
			// low-QoS queries inside the actor.
			let cached = await EmbeddingStore.shared.embeddings(for: deck.map(\.id))
			let cachedIDs = Set(cached.keys)
			// Songs we've permanently failed to embed get marked processed
			// up-front so the toolbar indicator's denominator reflects what
			// can actually finish in this pass — and so we don't burn the
			// 200ms breath re-attempting them.
			let failedIDs = await EmbeddingStore.shared.recentFailures(
				within: LibraryEmbeddingWarmer.failureRetryAfter
			)
			let skipIDs = cachedIDs.union(deck.map(\.id).filter { failedIDs.contains($0.rawValue) })
			await MainActor.run {
				for id in skipIDs {
					EmbeddingProgress.shared.recordProcessed(id)
				}
			}

			for song in deck where !skipIDs.contains(song.id) {
				do {
					_ = try await AudioEmbeddingService.embed(song: song)
					// `EmbeddingStore.store` already fired `recordProcessed`.
				} catch {
					// Mark permanent failures (noCatalogMatch, noPreview, …)
					// processed too — otherwise the indicator stalls at e.g.
					// 298/300 for songs that can't be resolved to a preview.
					await MainActor.run {
						EmbeddingProgress.shared.recordProcessed(song.id)
					}
				}
				// 500ms breath matches the library warmer's cadence and
				// stops the deck-warm from hammering MusicKit's catalog
				// endpoints (each embed can make 2-3 catalog calls in
				// `previewURL(for:)` before downloading) while the user
				// is mid-shuffle.
				try? await Task.sleep(for: .milliseconds(500))
			}

			// Deck is fully warm (or as warm as it'll get this session).
			// Hand off to the library warmer for the long tail — it
			// self-gates on WiFi + power, so this is cheap if conditions
			// aren't favourable.
			await LibraryEmbeddingWarmer.shared.runWarmPass()
			#if os(iOS)
				LibraryEmbeddingWarmer.scheduleNextBackgroundTask()
			#endif
		}
	}

	private static func dedupeUnion(_ pools: [Song]...) -> [Song] {
		var seen = Set<MusicItemID>()
		var union: [Song] = []
		union.reserveCapacity(pools.reduce(0) { $0 + $1.count })
		for pool in pools {
			for song in pool where seen.insert(song.id).inserted {
				union.append(song)
			}
		}
		return union
	}

	/// Which axis to sort the candidate pool on. One sort key per
	/// `MusicLibraryRequest`, so we run two requests in parallel.
	enum PoolSort {
		case playCount
		case libraryAddedDate
	}

	private static func fetchPool(sort: PoolSort, ascending: Bool, limit: Int) async throws -> [Song] {
		var request = MusicLibraryRequest<Song>()
		switch sort {
		case .playCount:
			request.sort(by: \.playCount, ascending: ascending)
		case .libraryAddedDate:
			request.sort(by: \.libraryAddedDate, ascending: ascending)
		}
		request.limit = limit
		let response = try await request.response()
		return Array(response.items)
	}

	/// Top-played library songs whose metadata matches the requested
	/// band's primary keyword. `filter(text:)` is a full-field search
	/// so the slice can include false positives, but the downstream
	/// energy classifier is what decides what each song's band
	/// actually is — this only widens the raw material.
	///
	/// Returns `[]` for `.any` (the base pools already cover everything)
	/// or when MusicKit fails the request; the union just absorbs the
	/// empty contribution without affecting the build's success.
	private static func fetchOptionalGenreSlice(for band: EnergyBand) async -> [Song] {
		guard band != .any, let keyword = primarySliceKeyword[band] else { return [] }
		var request = MusicLibraryRequest<Song>()
		request.filter(text: keyword)
		request.sort(by: \.playCount, ascending: false)
		request.limit = bandSliceLimit
		do {
			let response = try await request.response()
			return Array(response.items)
		} catch {
			return []
		}
	}
}
