//
//  EnergyClassifier.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Centroid-based refinement for the "Energy" walk-control band. Genre
//  keywords alone classify too coarsely — Apple's "Pop" can mean both
//  glacial art-pop and bouncy K-pop.
//
//  Two anchor sources, tried in order: bundled centroids from
//  hand-picked anchor albums (`EnergyCentroids.json`), then library
//  anchors via genre keywords (mean-pool the cached embeddings of songs
//  whose `genreNames` match the band's seed keywords).
//
//  Either way the threshold is self-calibrating: the median anchor-to-
//  centroid cosine. `AudioFeaturePrint` bunches pairwise cosine into a
//  narrow 0.80–0.94 band, so an absolute threshold doesn't generalise —
//  a tight band (e.g. classical) gets a high threshold, a broad one
//  (mellow) a low one. Songs with no cached embedding fall back to
//  `bandByGenre`, so a fresh install still filters reasonably.
//
//  Genres come from `GenreStore`, never `Song.genreNames`: that
//  attribute is always empty on library songs.
//

import Foundation
import MusicKit

enum EnergyClassifier {
	/// Minimum anchor count to trust a library-derived centroid; below
	/// this it's noise. Kept low so small libraries still get some
	/// embedding-aware filtering. Unused when bundled centroids exist.
	static let minAnchors = 5

	/// Returns the subset of `songs` that belong in `band`, or nil when
	/// the band is `.any` or there's neither bundled centroids nor enough
	/// library anchors. Nil signals the caller to fall back to the
	/// keyword filter.
	static func filter(
		_ songs: [Song],
		band: EnergyBand,
		embeddings: [MusicItemID: [Float]],
		genres: [MusicItemID: [String]]
	) -> [Song]? {
		if band == .any { return nil }

		// Argmax-with-genre-boost across all sub-styles in *all* bands:
		// a song is assigned the band of its best-matching sub-style.
		// Argmax (not OR-over-threshold) because cross-band centroid
		// distances are small here — mellow.downtempo and energetic.funk
		// sit at cos 0.98 — so a song's absolute cosine clears multiple
		// bands' thresholds and only relative ranking distinguishes them.
		if let bundle = EnergyCentroidsLoader.bundled, !bundle.bands.isEmpty {
			return filterUsingBundledCentroids(
				songs,
				band: band,
				bundle: bundle,
				embeddings: embeddings,
				genres: genres
			)
		}

		// Fallback: derive a centroid from library songs whose cached
		// genres match the band's seed keywords.
		guard let keywords = band.genreKeywords else { return nil }
		let lowered = keywords.map { $0.lowercased() }
		let anchorSet: Set<MusicItemID> = Set(
			songs.filter { song in
				(genres[song.id] ?? []).contains { genre in
					let g = genre.lowercased()
					return lowered.contains(where: g.contains)
				}
			}.map(\.id)
		)

		let anchorEmbeddings: [[Float]] = anchorSet.compactMap { embeddings[$0] }
		guard anchorEmbeddings.count >= minAnchors else { return nil }

		let centroid = mean(anchorEmbeddings)
		guard !centroid.isEmpty else { return nil }

		let anchorCosines = anchorEmbeddings.map {
			AudioEmbeddingService.cosineSimilarity($0, centroid)
		}
		let threshold = median(anchorCosines)

		return songs.filter { song in
			if let emb = embeddings[song.id] {
				return AudioEmbeddingService.cosineSimilarity(emb, centroid) >= threshold
			}
			// No cached embedding — fall back to the keyword signal.
			return anchorSet.contains(song.id)
		}
	}

	/// Boost added to a sub-style's score when the song's genre contains
	/// its slug as a substring. Big enough to break the ~0.01–0.03 cosine
	/// ties between competing cross-band sub-styles, small enough not to
	/// dominate when the embedding has clear signal.
	static let genreBoost: Float = 0.05

	/// Keep a song if it classifies into `targetBand`.
	///
	/// Embedded songs: band of the highest-scoring sub-style, requiring
	/// that sub-style's own threshold to clear — songs the embedding
	/// can't place reliably get dropped, not shoehorned into the nearest.
	/// Non-embedded songs: placed by `bandByGenre`.
	private static func filterUsingBundledCentroids(
		_ songs: [Song],
		band targetBand: EnergyBand,
		bundle: EnergyCentroidBundle,
		embeddings: [MusicItemID: [Float]],
		genres: [MusicItemID: [String]]
	) -> [Song] {
		guard let targetKey = targetBand.bundleKey else { return [] }

		let flat = flatten(bundle: bundle)
		guard !flat.isEmpty else { return [] }

		return songs.filter { song in
			let songGenres = genres[song.id] ?? []
			if let emb = embeddings[song.id] {
				return winningBundleKey(embedding: emb, genres: songGenres, flat: flat) == targetKey
			}
			return bandByGenre(songGenres) == targetBand
		}
	}

	/// Flattened sub-style entry — one row per (band, sub-style). Built
	/// once per pass and reused so bulk callers don't re-flatten per song.
	typealias FlatEntry = (bandKey: String, payload: EnergyCentroidPayload, token: String)

	static func flatten(bundle: EnergyCentroidBundle) -> [FlatEntry] {
		bundle.bands.flatMap { band, payloads in
			payloads
				.filter { !$0.centroid.isEmpty }
				.map { (band, $0, genreToken(forSlug: $0.subStyle)) }
		}
	}

	/// Single-song band assignment: the best-matching centroid's band for
	/// an embedded song, else `bandByGenre`. Nil if no reliable
	/// assignment is possible.
	///
	/// `genres` are cached genre names (`GenreStore`); `Song.genreNames`
	/// is always empty on library songs. Bulk callers should flatten once
	/// and use the `flat:` overload.
	static func band(
		embedding: [Float]?,
		genres: [String],
		bundle: EnergyCentroidBundle?
	) -> EnergyBand? {
		guard let bundle else { return nil }
		return band(
			embedding: embedding,
			genres: genres,
			bundle: bundle,
			flat: flatten(bundle: bundle)
		)
	}

	static func band(
		embedding: [Float]?,
		genres: [String],
		bundle _: EnergyCentroidBundle,
		flat: [FlatEntry]
	) -> EnergyBand? {
		if let emb = embedding, !flat.isEmpty,
		   let key = winningBundleKey(embedding: emb, genres: genres, flat: flat)
		{
			return EnergyBand.allCases.first { $0.bundleKey == key }
		}
		return bandByGenre(genres)
	}

	/// Argmax-with-genre-boost across all flattened sub-styles. Gated by
	/// the winning sub-style's own *raw-cosine* threshold — the boost
	/// helps pick the band but mustn't lower the "matched anything" bar.
	/// Nil when no sub-style clears its threshold.
	private static func winningBundleKey(
		embedding: [Float],
		genres: [String],
		flat: [FlatEntry]
	) -> String? {
		let lowered = genres.map { $0.lowercased() }
		var bestScore: Float = -.infinity
		var winningBand: String?
		var winningCosine: Float = 0
		var winningThreshold: Float = 0
		for entry in flat {
			let cosine = AudioEmbeddingService.cosineSimilarity(embedding, entry.payload.centroid)
			let genreMatch = lowered.contains { $0.contains(entry.token) }
			let score = cosine + (genreMatch ? genreBoost : 0)
			if score > bestScore {
				bestScore = score
				winningBand = entry.bandKey
				winningCosine = cosine
				winningThreshold = entry.payload.threshold
			}
		}
		guard let key = winningBand, winningCosine >= winningThreshold else { return nil }
		return key
	}

	/// Per-band anchor genres for the no-embedding fallback. A song is
	/// placed in whichever band its genres best match by `GenreSimilarity`
	/// lineage distance (graded partial credit; tags in no chain stay
	/// unclassified). Overlap is fine — argmax picks the strongest match,
	/// band order breaks ties toward lower energy. Expressed in
	/// `GenreSimilarity`'s lineage vocabulary, not slug substrings, which
	/// silently failed on Apple's punctuation ("Hip-Hop") and missed the
	/// most common tags ("Pop", "Rock", "Alternative").
	static let genreAnchors: [EnergyBand: [String]] = [
		.glacial: ["ambient", "classical", "new age", "singer/songwriter"],
		.mellow: ["soul", "r&b/soul", "jazz", "downtempo", "electronic", "soft rock", "folk", "indie pop", "adult contemporary"],
		.energetic: ["pop", "rock", "alternative", "dance", "funk", "disco", "hip-hop"],
		.intense: ["metal", "hard rock", "punk", "industrial", "techno", "dubstep", "hardcore"],
	]

	/// Place a song in a band by genre alone — the no-embedding fallback.
	/// Argmax of best pairwise `GenreSimilarity` against each band's
	/// `genreAnchors`; nil when nothing matches (genreless songs stay
	/// unclassified rather than shoehorned).
	static func bandByGenre(_ genres: [String]) -> EnergyBand? {
		guard !genres.isEmpty else { return nil }
		var best: EnergyBand?
		var bestScore: Float = 0
		for band in EnergyBand.allCases where band != .any {
			guard let anchors = genreAnchors[band] else { continue }
			var bandScore: Float = 0
			for genre in genres {
				for anchor in anchors {
					bandScore = max(bandScore, GenreSimilarity.pairwise(genre, anchor))
				}
			}
			if bandScore > bestScore {
				bestScore = bandScore
				best = band
			}
		}
		return best
	}

	/// Sub-style slug → substring-matchable token for Apple genre tags.
	/// Slugs use underscores ("hard_rock"), Apple uses spaces/slashes
	/// ("Hard Rock") — convert underscores so `.contains` matches.
	private static func genreToken(forSlug slug: String) -> String {
		slug.replacingOccurrences(of: "_", with: " ")
	}

	private static func mean(_ vectors: [[Float]]) -> [Float] {
		guard let first = vectors.first, !first.isEmpty else { return [] }
		let dims = first.count
		var sum = [Float](repeating: 0, count: dims)
		var counted: Float = 0
		for v in vectors where v.count == dims {
			for i in 0 ..< dims {
				sum[i] += v[i]
			}
			counted += 1
		}
		guard counted > 0 else { return [] }
		for i in 0 ..< dims {
			sum[i] /= counted
		}
		return sum
	}

	private static func median(_ values: [Float]) -> Float {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		let mid = sorted.count / 2
		if sorted.count.isMultiple(of: 2) {
			return (sorted[mid - 1] + sorted[mid]) / 2
		}
		return sorted[mid]
	}
}
