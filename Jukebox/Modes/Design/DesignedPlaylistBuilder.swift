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

	/// Distance penalty (in energy units) added to a recently-surfaced
	/// song when matching the curve, so fresh picks win on near-ties but
	/// recent ones still fill sparsely-covered stretches.
	static let recentEnergyPenalty = 0.05

	/// A pool song with its computed energy + recency, ready for
	/// nearest-curve matching.
	private struct EnergyCandidate {
		let song: Song
		let energy: Double
		let recent: Bool
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
		// Continuous energy per pool song: the band (centroid argmax for
		// embedded songs, GenreSimilarity anchors otherwise) floated by
		// cached BPM — see SongEnergy. Cache lookups only; no fresh embed
		// work. Songs we can't place (no embedding and no cached genre)
		// are dropped.
		let embeddings = await EmbeddingStore.shared.embeddings(for: pool.map(\.id))
		let genres = await GenreStore.shared.genres(for: pool.map(\.id))
		let bpms = await EmbeddingStore.shared.bpms(for: pool.map(\.id))
		// Bias away from songs surfaced in a recent Design run so iterating
		// on the curve doesn't keep resurfacing the playlist just discarded.
		let recentIDs = Set(await HistoryStore.shared.recentPlays(within: sessionWindow).keys)

		let bundle = EnergyCentroidsLoader.bundled
		let flat = bundle.map(EnergyClassifier.flatten(bundle:)) ?? []

		var candidates: [EnergyCandidate] = []
		candidates.reserveCapacity(pool.count)
		for song in pool {
			let band = bundle.flatMap {
				EnergyClassifier.band(
					embedding: embeddings[song.id],
					genres: genres[song.id] ?? [],
					bundle: $0,
					flat: flat
				)
			}
			guard let energy = SongEnergy.value(band: band, bpm: bpms[song.id]) else { continue }
			candidates.append(EnergyCandidate(
				song: song,
				energy: energy,
				recent: recentIDs.contains(song.id.rawValue)
			))
		}
		guard !candidates.isEmpty else { throw BuildError.noBandHasCandidates }

		// Walk the curve: each evenly-spaced sample picks the unused
		// candidate nearest the target energy, so the achieved playlist
		// tracks the drawn curve continuously instead of stepping through
		// four bands. Recent songs pay a small distance penalty — fresh
		// picks win on near-ties but recent ones still fill slots where a
		// stretch of the curve is sparsely covered.
		var selected: [Song] = []
		var usedIDs = Set<MusicItemID>()
		selected.reserveCapacity(count)
		for i in 0 ..< count {
			let t = count == 1 ? 0.5 : Double(i) / Double(count - 1)
			let y = curve.sample(at: t)
			var best: EnergyCandidate?
			var bestCost = Double.greatestFiniteMagnitude
			for candidate in candidates where !usedIDs.contains(candidate.song.id) {
				let cost = abs(candidate.energy - y) + (candidate.recent ? recentEnergyPenalty : 0)
				if cost < bestCost {
					bestCost = cost
					best = candidate
				}
			}
			if let best {
				selected.append(best.song)
				usedIDs.insert(best.song.id)
			}
		}

		return selected
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
