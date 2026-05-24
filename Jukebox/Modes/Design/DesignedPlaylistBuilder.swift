//
//  DesignedPlaylistBuilder.swift
//  Jukebox
//
//  Turns a five-point energy curve + a target song count into an ordered
//  list of songs. The curve is sampled at N evenly spaced t values; each
//  sample's [0, 1] Y is mapped to an EnergyBand; one song from that
//  band's candidate pool is picked per slot.
//
//  Why a fresh fetch instead of reusing the Songs-mode deck: that deck
//  is pre-walked for similarity transitions, which is the opposite of
//  what Design mode wants — here the transitions are dictated by the
//  user's curve. We need the broader unfiltered pool so every band has
//  enough candidates to fill its slots.
//

import Foundation
import MusicKit

enum DesignedPlaylistBuilder {
	/// Per-pool fetch limit. Two pools (nostalgia + discovery) get
	/// dedupe-unioned for a ~3-4k candidate set — enough material that
	/// every energy band has dozens of candidates after classification.
	static let poolLimit = 2000

	/// Per-band fetch limit for the genre-keyword slices. The two base
	/// pools (top-played + recently-added) bias toward the user's
	/// listening habits, so a strictly mellow listener never sees their
	/// long-tail intense tracks surface. Each band gets a separate
	/// `filter(text:)` slice sorted by play count, sized to capture the
	/// user's full affinity for that band without ballooning memory.
	static let bandSliceLimit = 500

	/// Window for the within-session "just generated" downrank. Tuned to
	/// cover an active iteration sitting — generate, listen to a bit,
	/// tweak the curve, regenerate — without penalising last week's runs.
	static let sessionWindow: TimeInterval = 4 * 3600

	/// The single most-distinctive genre keyword per band — the one we
	/// use for the supplementary `filter(text:)` slice. Each band's
	/// `genreKeywords` array carries broader-coverage terms (e.g.
	/// "pop"/"rock") that would either over-fetch or pull material into
	/// the wrong band; this picks the narrowest term that still has
	/// realistic library coverage.
	private static let primarySliceKeyword: [EnergyBand: String] = [
		.glacial: "ambient",
		.mellow: "soul",
		.energetic: "dance",
		.intense: "metal",
	]

	enum BuildError: Error, LocalizedError {
		case emptyPool
		case noBandHasCandidates

		var errorDescription: String? {
			switch self {
			case .emptyPool:
				"Couldn't find enough songs in your library to design a playlist."
			case .noBandHasCandidates:
				"Couldn't classify any of your songs into an energy band."
			}
		}
	}

	static func build(curve: EnergyCurve, count: Int) async throws -> [Song] {
		// Two base pools + one slice per concrete band, all in parallel.
		// The base pools (top-played + recently-added) carry the bias of
		// the user's listening habits — a strictly mellow listener never
		// surfaces their long-tail intense tracks through those alone.
		// The per-band `filter(text:)` slices guarantee every band has
		// genuine library candidates regardless of that bias; their
		// downstream classification still flows through the same
		// centroid/keyword path, so misfiles don't slip into the wrong
		// bucket.
		let pool = try await withThrowingTaskGroup(of: [Song].self) { group in
			group.addTask {
				try await fetchPool(sort: .playCount, ascending: false)
			}
			group.addTask {
				try await fetchPool(sort: .libraryAddedDate, ascending: false)
			}
			for band in EnergyBand.concreteOrdered {
				group.addTask {
					// Band slices are best-effort: a keyword with zero
					// library matches just contributes nothing. Letting
					// one slice failure abort the whole build would be
					// too brittle for a five-fetch fan-out.
					(try? await fetchGenreSlice(band: band, limit: bandSliceLimit)) ?? []
				}
			}
			var all: [Song] = []
			for try await chunk in group {
				all.append(contentsOf: chunk)
			}
			return dedupe(all)
		}
		guard !pool.isEmpty else { throw BuildError.emptyPool }

		// Embeddings drive the centroid classifier. Cache lookups only —
		// we deliberately don't kick off fresh embedding work here. Songs
		// without a cached embedding fall through to the keyword classifier.
		let embeddings = await EmbeddingStore.shared.embeddings(for: pool.map(\.id))

		// Bucket the pool by band once, up front. Each band's bucket is
		// independent of the others — same song could classify into
		// multiple bands at the keyword level (e.g. "Classical" hits
		// glacial *and* mellow), but the deduper below picks each song
		// at most once across the final playlist.
		var byBand: [EnergyBand: [Song]] = [:]
		for band in EnergyBand.concreteOrdered {
			byBand[band] = candidates(in: band, pool: pool, embeddings: embeddings)
		}

		// Bias each band away from songs that turned up in a Design run
		// within the session — iterating on the curve shouldn't keep
		// resurfacing the playlist the user just discarded. `HistoryStore`
		// records every Design generation at build time (before playback),
		// so a short window catches discards without any extra bookkeeping.
		// Soft downrank, not exclusion: `pop` drains via `popLast`, so
		// putting recent songs at the front of each band's array means
		// fresh candidates get picked first while recent ones remain
		// available if a narrow band runs dry — curve fidelity over novelty.
		let recentIDs = Set(await HistoryStore.shared.recentPlays(within: sessionWindow).keys)
		for band in byBand.keys {
			guard let pool = byBand[band] else { continue }
			var fresh: [Song] = []
			var recent: [Song] = []
			fresh.reserveCapacity(pool.count)
			for song in pool {
				if recentIDs.contains(song.id.rawValue) {
					recent.append(song)
				} else {
					fresh.append(song)
				}
			}
			fresh.shuffle()
			recent.shuffle()
			byBand[band] = recent + fresh
		}

		guard byBand.values.contains(where: { !$0.isEmpty }) else {
			throw BuildError.noBandHasCandidates
		}

		var selected: [Song] = []
		var usedIDs = Set<MusicItemID>()
		selected.reserveCapacity(count)

		for i in 0 ..< count {
			let t = count == 1 ? 0.5 : Double(i) / Double(count - 1)
			let y = curve.sample(at: t)
			let requestedBand = EnergyBand.forCurveValue(y)
			if let song = pop(
				preferredBand: requestedBand,
				usedIDs: &usedIDs,
				byBand: &byBand
			) {
				selected.append(song)
			}
		}

		return selected
	}

	/// Try the preferred band first, then spiral outward to neighbouring
	/// bands by band-index distance. Spiraling rather than collapsing to
	/// any-band keeps the achieved curve as close as possible to the
	/// requested one when a band is exhausted.
	private static func pop(
		preferredBand: EnergyBand,
		usedIDs: inout Set<MusicItemID>,
		byBand: inout [EnergyBand: [Song]]
	) -> Song? {
		let order = EnergyBand.concreteOrdered
		guard let preferredIdx = order.firstIndex(of: preferredBand) else { return nil }
		for offset in 0 ..< order.count {
			for sign in offset == 0 ? [0] : [-1, 1] {
				let idx = preferredIdx + sign * offset
				guard order.indices.contains(idx) else { continue }
				let band = order[idx]
				while var pool = byBand[band], let candidate = pool.popLast() {
					byBand[band] = pool
					if usedIDs.insert(candidate.id).inserted {
						return candidate
					}
				}
			}
		}
		return nil
	}

	private static func candidates(
		in band: EnergyBand,
		pool: [Song],
		embeddings: [MusicItemID: [Float]]
	) -> [Song] {
		// Centroid classifier first; falls through to keyword filter on
		// nil (no bundled centroids, or no anchor embeddings cached);
		// falls through to keyword filter on empty result (centroid had
		// no matches for this band).
		if let centroid = EnergyClassifier.filter(pool, band: band, embeddings: embeddings),
		   !centroid.isEmpty
		{
			return centroid
		}
		if let keyword = filterByKeyword(pool, band: band), !keyword.isEmpty {
			return keyword
		}
		return []
	}

	/// Pool-level keyword fallback — same shape as `GemDeckBuilder`'s
	/// private helper. Duplicated rather than exposed so each builder
	/// owns its own filtering policy.
	private static func filterByKeyword(_ songs: [Song], band: EnergyBand) -> [Song]? {
		guard let keywords = band.genreKeywords else { return nil }
		let lowered = keywords.map { $0.lowercased() }
		return songs.filter { song in
			song.genreNames.contains { genre in
				let g = genre.lowercased()
				return lowered.contains(where: g.contains)
			}
		}
	}

	private static func dedupe(_ songs: [Song]) -> [Song] {
		var seen = Set<MusicItemID>()
		var out: [Song] = []
		out.reserveCapacity(songs.count)
		for song in songs where seen.insert(song.id).inserted {
			out.append(song)
		}
		return out
	}

	private enum PoolSort { case playCount, libraryAddedDate }

	private static func fetchPool(sort: PoolSort, ascending: Bool) async throws -> [Song] {
		var request = MusicLibraryRequest<Song>()
		switch sort {
		case .playCount: request.sort(by: \.playCount, ascending: ascending)
		case .libraryAddedDate: request.sort(by: \.libraryAddedDate, ascending: ascending)
		}
		request.limit = poolLimit
		let response = try await request.response()
		return Array(response.items)
	}

	/// Top-played library songs whose metadata matches the band's primary
	/// keyword. `MusicLibraryRequest.filter(text:)` is a full-field
	/// search (title/artist/album/genre), so a "metal" filter pulls in
	/// the occasional false positive — but the downstream centroid
	/// classifier is what actually decides what ends up in each band's
	/// bucket, and this is only here to *broaden* the candidate set
	/// past what playCount+libraryAddedDate alone surface.
	private static func fetchGenreSlice(band: EnergyBand, limit: Int) async throws -> [Song] {
		guard let keyword = primarySliceKeyword[band] else { return [] }
		var request = MusicLibraryRequest<Song>()
		request.filter(text: keyword)
		request.sort(by: \.playCount, ascending: false)
		request.limit = limit
		let response = try await request.response()
		return Array(response.items)
	}
}
