//
//  DesignedPlaylistBuilder.swift
//  Jukebox
//
//  Turns a five-point energy curve + a target song count into an ordered
//  list of songs.
//
//  Fresh fetch rather than reusing the Songs-mode deck: that deck is
//  pre-walked for similarity transitions, the opposite of what Design
//  mode wants — here transitions are dictated by the curve, so we need
//  the broader unfiltered pool.
//

import Foundation
import MusicKit

enum DesignedPlaylistBuilder {
	/// Per-pool fetch limit. Two pools dedupe-union to a ~3-4k candidate
	/// set so every band has dozens of candidates after classification.
	static let poolLimit = 2000

	/// Per-band fetch limit for the genre-keyword slices. The base pools
	/// bias toward the user's habits, so a strictly mellow listener never
	/// surfaces their long-tail intense tracks; each band gets its own
	/// `filter(text:)` slice to guarantee candidates.
	static let bandSliceLimit = 500

	/// Window for the within-session "just generated" downrank. Covers an
	/// active iteration sitting without penalising last week's runs.
	static let sessionWindow: TimeInterval = 4 * 3600

	/// Narrowest distinctive genre keyword per band for the supplementary
	/// `filter(text:)` slice — broader terms over-fetch or cross bands.
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

	/// Distance penalty (in energy units) for a recently-surfaced song, so
	/// fresh picks win on near-ties but recent ones still fill sparse
	/// stretches of the curve.
	static let recentEnergyPenalty = 0.05

	private struct EnergyCandidate {
		let song: Song
		let energy: Double
		let recent: Bool
	}

	static func build(curve: EnergyCurve, count: Int) async throws -> [Song] {
		// Two base pools + one slice per band, in parallel. The per-band
		// slices guarantee candidates despite the base pools' bias toward
		// the user's habits; everything still flows through the same
		// classifier, so misfiles don't reach the wrong bucket.
		let pool = try await withThrowingTaskGroup(of: [Song].self) { group in
			group.addTask {
				try await fetchPool(sort: .playCount, ascending: false)
			}
			group.addTask {
				try await fetchPool(sort: .libraryAddedDate, ascending: false)
			}
			for band in EnergyBand.concreteOrdered {
				group.addTask {
					// Best-effort: one slice failing shouldn't abort the build.
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

		// Cache lookups only — no fresh embedding work here. Songs without
		// a cached embedding fall through to the keyword classifier; ones
		// with neither embedding nor cached genre are dropped.
		let embeddings = await EmbeddingStore.shared.embeddings(for: pool.map(\.id))
		let genres = await GenreStore.shared.genres(for: pool.map(\.id))
		let bpms = await EmbeddingStore.shared.bpms(for: pool.map(\.id))
		// Bias away from songs from a recent Design run so iterating on the
		// curve doesn't resurface the playlist just discarded.
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
		// candidate nearest the target energy, so the playlist tracks the
		// curve continuously instead of stepping through four bands.
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

	/// Top-played library songs matching the band's primary keyword.
	/// `filter(text:)` is a full-field search, so it pulls occasional
	/// false positives — fine, since the centroid classifier decides the
	/// final bucket and this only broadens the candidate set.
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
