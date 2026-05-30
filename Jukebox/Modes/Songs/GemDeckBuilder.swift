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
/// Strategy: fetch three complementary candidate pools (nostalgia:
/// highest playCount; discovery: oldest libraryAddedDate; freshness:
/// newest libraryAddedDate), dedupe, score with `GemScorer`, keep the
/// top N, then shuffle within it for per-session variety.
///
/// Three pools instead of scanning the whole library: a heavy user has
/// 5k–50k songs and paging all of them per appearance is wasteful. The
/// accepted cost: a song middling on all three axes can miss every pool.
enum GemDeckBuilder {
	/// Baseline per-pool fetch limit when no walk filters are active.
	/// 1000 gives a healthy three-pool union (~2–2.5k after dedupe)
	/// without scanning the whole library; higher pulled more MusicKit
	/// hydration than needed and stretched shuffle past tolerance.
	/// `poolSize(for:)` scales this up when filters narrow the pool.
	static let basePoolSize = 1000
	/// Hard ceiling on a single pool fetch. 4× the baseline — much higher
	/// approaches a full-library scan for 50k libraries.
	static let maxPoolSize = 6000
	/// Top-N kept after scoring, then shuffled for per-session order.
	static let deckSize = 300

	/// Per-pool fetch limit adapted to active filters. MusicKit can't
	/// range-filter on releaseDate and the energy classifier needs an
	/// unfiltered pool, so both run client-side post-fetch — and a strict
	/// "1960s Glacial" query can collapse the candidate set to a handful.
	/// Growing the fetch when filters narrow gives them more to bite into.
	///
	/// Multipliers compound, capped at `maxPoolSize`:
	///  - energy filter active  → ×2
	///  - decade range narrow   → ×3 (span ≤ 30 years, i.e. ≤ 3 decades)
	///  - decade range bounded  → ×2 (4+ decades but not the full range)
	static func poolSize(for controls: WalkControls) -> Int {
		var multiplier = 1
		if controls.energy.isActive { multiplier *= 2 }
		if !controls.decadeRange.isUnbounded {
			let span = controls.decadeRange.upper - controls.decadeRange.lower
			multiplier *= (span <= 30 ? 3 : 2)
		}
		return min(basePoolSize * multiplier, maxPoolSize)
	}

	struct BuildResult {
		let deck: [Song]
		let scannedCount: Int
		/// Min/max release decades from the *unfiltered* pool, so the
		/// range slider's thumbs only travel decades that exist in the
		/// library. Nil when the pool has no dated candidates.
		let libraryDecadeBounds: ClosedRange<Int>?
		/// `OriginalReleaseStore` snapshot, so the shuffle-avoidance hint
		/// can read a focused song's decade synchronously without an
		/// actor hop.
		let originals: [MusicItemID: Date]
	}

	/// Final-result API: consumes the stream and returns the last emission.
	/// Forwards the walk parameters so callers off the dial (App Intents,
	/// Control Center) build the same filtered deck `SongsView` does.
	static func build(
		now: Date = Date(),
		controls: WalkControls = .default,
		wideSample: Bool = false,
		avoidDecade: Int? = nil,
		avoidArtist: String? = nil
	) async throws -> BuildResult {
		var last: BuildResult?
		for try await result in buildStreaming(
			now: now,
			wideSample: wideSample,
			controls: controls,
			avoidDecade: avoidDecade,
			avoidArtist: avoidArtist
		) {
			last = result
		}
		return last ?? BuildResult(deck: [], scannedCount: 0, libraryDecadeBounds: nil, originals: [:])
	}

	/// Default ± landing spread around the deck head, shared by the dial's
	/// cold-launch landing and the off-dial intents.
	static let defaultLandingSpread = 6

	/// A random landing index within ±`spread` of the deck head, wrapped
	/// modularly. Mirrors the dial's seed-landing so an intent-built deck
	/// starts somewhere fresh near the top instead of always at index 0.
	static func seedIndex(deckCount: Int, spread: Int = defaultLandingSpread) -> Int {
		guard deckCount > 1 else { return 0 }
		let s = min(spread, max(0, deckCount - 1))
		guard s > 0 else { return 0 }
		let offset = Int.random(in: -s ... s)
		return ((offset % deckCount) + deckCount) % deckCount
	}

	/// `length` songs from `startIndex`, wrapping the deck modularly (it's a
	/// cylinder, so a tail seed still gets a full runway). The runway both
	/// `SongsView.play(from:)` and the intents seed the queue with.
	static func runway(deck: [Song], startIndex: Int, length: Int = 20) -> [Song] {
		guard !deck.isEmpty else { return [] }
		let n = min(length, deck.count)
		return (0 ..< n).map { deck[(startIndex + $0) % deck.count] }
	}

	/// Builds the deck end-to-end: three pools in parallel, deduped,
	/// scored, capped, walk-ordered. Yields exactly once. A nostalgia-only
	/// partial yield was tried to make the dial interactive sooner on cold
	/// launch, but the swap when the full deck landed was jarring — the
	/// dial now waits behind the loading overlay.
	///
	/// Wrapped in `AsyncThrowingStream` (not `async throws`) so
	/// `onTermination` can cancel the fetch task when the caller bails.
	/// Multiplier on `deckSize` for the candidate slice when
	/// `wideSample: true`. Larger = more super-shuffle variety, at the
	/// cost of lower-scored gems entering the deck.
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
					// Our own recent-play log supplements
					// `Song.lastPlayedDate`, which lags or fails to update
					// for `SystemMusicPlayer` plays on library-only items —
					// just-queued songs would otherwise resurface as
					// high-ranked seeds. Soft penalty, not hard exclude, so
					// small libraries don't exhaust the 14-day window.
					let recentPlays = await HistoryStore.shared.recentPlays(within: 14 * 86400)
					let scorer = GemScorer(
						now: now,
						recentPlays: recentPlays
					)
					// User-removed songs/albums/artists. Hard-excluded below
					// with no soft-fallback resurfacing — they stay gone.
					let exclusions = await ExclusionStore.shared.exclusions()
					let seed = UInt64.random(in: 0 ... UInt64.max)

					// Gate fan-out behind the MusicKit probe: parallel
					// `MusicLibraryRequest`s racing `musicd`'s cold-init
					// wedge the daemon. See `MusicKitWarmup`.
					await MusicKitWarmup.waitUntilReady()

					let limit = poolSize(for: controls)
					async let nostalgiaTask = fetchPool(sort: .playCount, ascending: false, limit: limit)
					async let discoveryTask = fetchPool(sort: .libraryAddedDate, ascending: true, limit: limit)
					async let freshnessTask = fetchPool(sort: .libraryAddedDate, ascending: false, limit: limit)
					// Targeted slice for the requested band: a mellow-leaning
					// library would otherwise post-filter the base pools to
					// almost nothing when asked for Intense or Energetic.
					// No-ops when the filter is `.any`.
					async let bandSliceTask = fetchOptionalGenreSlice(for: controls.energy.target.map(EnergyBand.forValue))

					let nostalgia = try await nostalgiaTask
					let discovery = try await discoveryTask
					let freshness = try await freshnessTask
					let bandSlice = await bandSliceTask
					let union = dedupeUnion(nostalgia, discovery, freshness, bandSlice)
						.filter { !exclusions.excludes(song: $0) }
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

					// Background-embed any uncached deck songs so the next
					// session's walk converges on real audio similarity
					// instead of the genre fallback. Fire-and-forget.
					warmEmbeddings(for: final.deck)
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Per-band fetch limit for the genre-keyword slice fetched alongside
	/// the base pools for a non-`.any` band. The base pools sort by
	/// playCount / libraryAddedDate, inheriting the user's listening bias —
	/// a strictly mellow listener never surfaces their long-tail intense
	/// tracks through those alone.
	static let bandSliceLimit = 500

	/// Most-distinctive genre keyword per band — the narrowest term with
	/// realistic library coverage (`genreKeywords` has broader terms like
	/// "pop"/"rock" that over-fetch into the wrong bucket). Duplicated
	/// from `DesignedPlaylistBuilder` so each builder owns its policy.
	private static let primarySliceKeyword: [EnergyBand: String] = [
		.glacial: "ambient",
		.mellow: "soul",
		.energetic: "dance",
		.intense: "metal",
	]

	/// Cap on tracks per artist in the deck. The walk's artist-lookback
	/// (≤2) only prevents adjacency; a pool of 30 same-artist tracks lets
	/// the walk run out of alternatives and clump them anyway. Capping at
	/// the deck stage keeps variety on hand.
	static let perArtistCap = 8

	/// Cap on tracks per album — heavy library skew was filling the deck
	/// with full-album listings. 3 lets distinctive albums surface
	/// multiple tracks without dominating.
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
		// Cache only holds remasters/compilations the resolver has looked
		// up; uncached songs fall through to `Song.releaseDate` inside
		// `releaseDecade(override:)`.
		let originals = await OriginalReleaseStore.shared.originalDates(for: songs.map(\.id))

		// Decade bounds from the *unfiltered* pool — the filter steps
		// below don't change the answer.
		let libraryDecadeBounds: ClosedRange<Int>? = {
			let decades = songs.compactMap { $0.releaseDecade(override: originals[$0.id]) }
			guard let lo = decades.min(), let hi = decades.max() else { return nil }
			return lo ... hi
		}()

		// Energy filtering needs embeddings for the whole pool (the
		// centroid classifier scores everything), not just the top-300.
		// For "Any" we defer the fetch until after `top` is picked, to
		// avoid loading ~3000 vectors we don't need.
		var poolEmbeddings: [MusicItemID: [Float]]?
		var poolGenres: [MusicItemID: [String]] = [:]
		var poolBpms: [MusicItemID: Double] = [:]
		if controls.energy.isActive {
			poolEmbeddings = await EmbeddingStore.shared.embeddings(for: songs.map(\.id))
			poolGenres = await GenreStore.shared.genres(for: songs.map(\.id))
			poolBpms = await EmbeddingStore.shared.bpms(for: songs.map(\.id))
		}

		// Energy: keep songs whose continuous energy (band center floated
		// by BPM, see SongEnergy) sits within the target window.
		// Unplaceable songs are excluded; soft-fail to the whole pool if a
		// too-narrow window would blank the deck.
		let energyPool: [Song]
		if let target = controls.energy.target, let bundle = EnergyCentroidsLoader.bundled {
			let flat = EnergyClassifier.flatten(bundle: bundle)
			let filtered = songs.filter { song in
				let band = EnergyClassifier.band(
					embedding: poolEmbeddings?[song.id],
					genres: poolGenres[song.id] ?? [],
					bundle: bundle,
					flat: flat
				)
				guard let energy = SongEnergy.value(band: band, bpm: poolBpms[song.id]) else { return false }
				return abs(energy - target) <= controls.energy.window
			}
			energyPool = filtered.isEmpty ? songs : filtered
		} else {
			energyPool = songs
		}

		// Decade range: hard filter on releaseDecade. Dateless songs pass
		// through (don't punish missing metadata). Soft-fall-back to the
		// undecade-filtered pool if the range matches nothing.
		let pool: [Song]
		if controls.decadeRange.isUnbounded {
			pool = energyPool
		} else {
			let decadeFiltered = energyPool.filter { song in
				guard let decade = song.releaseDecade(override: originals[song.id]) else { return true }
				return controls.decadeRange.contains(decade)
			}
			pool = decadeFiltered.isEmpty ? energyPool : decadeFiltered
		}

		let ranked = scorer.scoreAndRank(pool)
		let top: [Song]
		if wideSample {
			// Super-shuffle: widen the slice and sample down to deckSize so
			// the deck genuinely turns over instead of re-walking the same
			// top-300. System RNG gives a fresh sample per press even
			// though scoring is deterministic. Caps applied to the widened
			// pool first so the shuffled deck still respects them.
			let wideCount = min(deckSize * wideSampleMultiplier, ranked.count)
			let widePool = capPerArtistAndAlbum(
				ranked.prefix(wideCount).map(\.song),
				limit: deckSize * wideSampleMultiplier
			)
			top = Array(widePool.shuffled().prefix(deckSize))
		} else {
			top = capPerArtistAndAlbum(ranked.map(\.song), limit: deckSize)
		}
		// Reuse pool-wide embeddings if the classifier loaded them;
		// otherwise fetch just the top-N for the walk.
		let embeddings: [MusicItemID: [Float]]
		if let emb = poolEmbeddings {
			let topIDs = Set(top.map(\.id))
			embeddings = emb.filter { topIDs.contains($0.key) }
		} else {
			embeddings = await EmbeddingStore.shared.embeddings(for: top.map(\.id))
		}
		// BPM isn't pool-wide cached, so fetch fresh for the top-N. Only
		// songs with a non-nil BPM come back; the walk gates on per-pair
		// coverage.
		let bpms = await EmbeddingStore.shared.bpms(for: top.map(\.id))
		// `genreNames` is empty on library songs, so cached genres are the
		// only genre signal for the walk's similarity term.
		let genres = await GenreStore.shared.genres(for: top.map(\.id))
		let blockedPairs = await TransitionFeedbackStore.shared.allBlockedPairs()
		let deck = SongDeckWalk.walk(
			songs: top,
			embeddings: embeddings,
			bpms: bpms,
			originals: originals,
			genres: genres,
			blockedPairs: blockedPairs,
			seed: seed,
			controls: controls,
			avoidDecade: avoidDecade,
			avoidArtist: avoidArtist
		)
		return BuildResult(
			deck: deck,
			scannedCount: songs.count,
			libraryDecadeBounds: libraryDecadeBounds,
			originals: originals
		)
	}

	/// Keeps each song unless its artist or album has hit the cap, until
	/// `limit` or exhaustion. An empty `albumTitle` skips the album cap so
	/// metadata-less tracks don't all land in one "unknown album" bucket.
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
		// `.utility` not `.background`: narrows the QoS gap to the
		// user-initiated walk reads on the same actor, avoiding a
		// priority-inversion flag when a walk fetch lands behind us.
		Task.detached(priority: .utility) {
			// One bulk fetch, not 300 actor hops, so the walk's
			// `embeddings(for:)` isn't stuck behind low-QoS queries.
			let cached = await EmbeddingStore.shared.embeddings(for: deck.map(\.id))
			let cachedIDs = Set(cached.keys)
			// Mark permanent-fail songs processed up-front so the indicator
			// denominator reflects what can finish, and we don't re-attempt.
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
					// Mark permanent failures processed too, else the
					// indicator stalls at e.g. 298/300 for unresolvable songs.
					await MainActor.run {
						EmbeddingProgress.shared.recordProcessed(song.id)
					}
				}
				// 500ms breath so the deck-warm doesn't hammer MusicKit's
				// catalog endpoints (2-3 calls per embed in
				// `previewURL(for:)`) while the user is mid-shuffle.
				try? await Task.sleep(for: .milliseconds(500))
			}

			// Original-date resolution: same breath + skip-if-resolved as
			// the embedding pass, one catalog round-trip per song per
			// install. Decade-filter accuracy grows as each shuffle caches
			// more remaster/compilation origin years.
			let resolved = await OriginalReleaseStore.shared.resolvedIDs(for: deck.map(\.id))
			for song in deck where !resolved.contains(song.id.rawValue) {
				try? await OriginalReleaseResolver.resolveAndStore(song: song)
				try? await Task.sleep(for: .milliseconds(500))
			}

			// Hand off the long tail to the library warmer. Foreground
			// pass gates on WiFi + not-Low-Power-Mode (no external-power
			// requirement) so it progresses while browsing on battery.
			await LibraryEmbeddingWarmer.shared.runWarmPass(requirePower: false)
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

	/// Which axis to sort the candidate pool on.
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

	/// Top-played songs matching the band's primary keyword.
	/// `filter(text:)` is full-field so the slice may include false
	/// positives — the energy classifier decides the real band; this
	/// only widens the raw material. Returns `[]` for `.any` or on
	/// request failure.
	private static func fetchOptionalGenreSlice(for band: EnergyBand?) async -> [Song] {
		guard let band, band != .any, let keyword = primarySliceKeyword[band] else { return [] }
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
