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

	struct Result {
		let songs: [Song]
		/// Per-slot band actually used (may differ from the requested
		/// band when a fallback to an adjacent band fired). Exposed so
		/// the result sheet can plot what was achieved next to what was
		/// asked for.
		let bandsUsed: [EnergyBand]
	}

	static func build(curve: EnergyCurve, count: Int) async throws -> Result {
		// Two pools in parallel — same strategy as GemDeckBuilder. Heavy
		// users have 5k–50k library songs so a full scan is wasteful; the
		// nostalgia + discovery union covers both "songs you play" and
		// "songs you forgot about" without paging everything.
		async let nostalgiaTask = fetchPool(sort: .playCount, ascending: false)
		async let discoveryTask = fetchPool(sort: .libraryAddedDate, ascending: false)
		let pool = dedupe(try await nostalgiaTask + (try await discoveryTask))
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
		// Shuffle within each band once so a fresh design run doesn't
		// always pull the same top-scoring candidate per slot.
		for band in byBand.keys {
			byBand[band]?.shuffle()
		}

		guard byBand.values.contains(where: { !$0.isEmpty }) else {
			throw BuildError.noBandHasCandidates
		}

		var selected: [Song] = []
		var usedIDs = Set<MusicItemID>()
		var bandsUsed: [EnergyBand] = []
		selected.reserveCapacity(count)
		bandsUsed.reserveCapacity(count)

		for i in 0 ..< count {
			let t = count == 1 ? 0.5 : Double(i) / Double(count - 1)
			let y = curve.sample(at: t)
			let requestedBand = EnergyBand.forCurveValue(y)
			if let pick = pop(
				preferredBand: requestedBand,
				usedIDs: &usedIDs,
				byBand: &byBand
			) {
				selected.append(pick.song)
				bandsUsed.append(pick.band)
			}
		}

		return Result(songs: selected, bandsUsed: bandsUsed)
	}

	/// Try the preferred band first, then spiral outward to neighbouring
	/// bands by band-index distance. Spiraling rather than collapsing to
	/// any-band keeps the achieved curve as close as possible to the
	/// requested one when a band is exhausted.
	private static func pop(
		preferredBand: EnergyBand,
		usedIDs: inout Set<MusicItemID>,
		byBand: inout [EnergyBand: [Song]]
	) -> (song: Song, band: EnergyBand)? {
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
						return (candidate, band)
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
}
