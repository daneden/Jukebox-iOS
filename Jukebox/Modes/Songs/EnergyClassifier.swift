//
//  EnergyClassifier.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Centroid-based refinement for the "Energy" walk-control band. Genre
//  keywords alone classify too coarsely — Apple's "Pop" can mean both
//  glacial ambient-adjacent art-pop and bouncy K-pop.
//
//  Two anchor sources, tried in order:
//   1. Bundled centroids derived from hand-picked anchor albums
//      (flowstate.daneden.me). These are baked on-device by the debug
//      builder and committed as `EnergyCentroids.json`. Curated, so
//      much more reliable than genre tags — used when present.
//   2. Library anchors via genre keywords. Original behaviour: pull
//      songs whose `genreNames` match the band's seed keywords,
//      mean-pool their cached `AudioFeaturePrint` embeddings.
//
//  Either way the threshold is self-calibrating: the median anchor-
//  to-centroid cosine. `AudioFeaturePrint` empirically bunches pairwise
//  cosine into a narrow 0.80–0.94 band (see SongDeckWalk.similarity),
//  so an absolute threshold doesn't generalise — a tight band (low
//  intra-anchor variance, e.g. classical) gets a high threshold; a
//  broad one (mellow, which spans pop / soul / jazz / soft rock) gets
//  a low one. Songs without a cached embedding fall back to the genre
//  keyword signal — so a fresh install with zero embeddings cached
//  still gets reasonable filtering.
//

import Foundation
import MusicKit

enum EnergyClassifier {
	/// Minimum anchor count required to trust a library-derived
	/// centroid. Below this the centroid is noise — bail and let the
	/// caller fall back to the keyword filter. Picked low so small
	/// libraries still see some embedding-aware filtering. Unused
	/// when bundled centroids are present.
	static let minAnchors = 5

	/// Returns the subset of `songs` that belong in `band`, or nil
	/// when the band is `.any` or we have neither bundled centroids
	/// nor enough library anchors to build a reliable centroid in
	/// real time. nil signals the caller to soft-fall-back to the
	/// keyword filter.
	static func filter(
		_ songs: [Song],
		band: EnergyBand,
		embeddings: [MusicItemID: [Float]]
	) -> [Song]? {
		if band == .any { return nil }

		// Preferred path: hand-picked anchor centroids baked into the
		// bundle (see EnergyCentroids.swift). Each band carries several
		// sub-style centroids. We use argmax-with-genre-boost across all
		// sub-styles in *all* bands — a song is assigned to whichever
		// band contains its best-matching sub-style.
		//
		// Argmax (not OR-over-threshold) because cross-band centroid
		// distances are small in this embedding space — mellow.downtempo
		// and energetic.funk sit at cos 0.98 to each other. A song's
		// absolute cosine clears multiple bands' thresholds; only its
		// *relative* ranking distinguishes them. Genre boost breaks ties
		// where Apple's genre tag matches a sub-style slug (sub-styles
		// are Apple-aligned: "metal", "hip_hop", "industrial", etc.).
		if let bundle = EnergyCentroidsLoader.bundled, !bundle.bands.isEmpty {
			return filterUsingBundledCentroids(
				songs,
				band: band,
				bundle: bundle,
				embeddings: embeddings
			)
		}

		// Fallback: derive a centroid from library songs whose
		// `genreNames` match the band's seed keywords.
		guard let keywords = band.genreKeywords else { return nil }
		let lowered = keywords.map { $0.lowercased() }
		let anchorSet: Set<MusicItemID> = Set(
			songs.filter { song in
				song.genreNames.contains { genre in
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
			// No cached embedding — fall back to the keyword signal
			// for this individual song. Keeps fresh-install behaviour
			// equivalent to keyword-only filtering on songs that
			// haven't been embedded yet, while embedded songs benefit
			// from the centroid refinement.
			return anchorSet.contains(song.id)
		}
	}

	/// Boost added to a sub-style's score when the song's Apple
	/// `genreNames` contains the sub-style's slug as a substring. Big
	/// enough to break the ~0.01–0.03 cosine ties that competing
	/// sub-styles across bands typically sit at, small enough not to
	/// dominate when the embedding has clear signal. Tunable — revisit
	/// if assignments start feeling genre-driven rather than sound-driven.
	static let genreBoost: Float = 0.05

	/// Argmax-with-genre-boost across every sub-style in every band.
	///
	/// Embedded songs: the song's band is the band of its highest-scoring
	/// sub-style (score = cosine + α·1[genre matches slug]). We also
	/// require the winning sub-style's own threshold to clear — songs
	/// the embedding can't place anywhere reliably get dropped rather
	/// than shoehorned into the nearest band.
	///
	/// Non-embedded songs: substring-match the song's `genreNames`
	/// against the target band's sub-style slugs (Apple-aligned, so this
	/// works as a sub-style-granular fallback). Multi-band overlap is
	/// possible for ambiguous tags (e.g. "Classical" hits both glacial
	/// and mellow); the user selects one band at a time so this is fine.
	private static func filterUsingBundledCentroids(
		_ songs: [Song],
		band targetBand: EnergyBand,
		bundle: EnergyCentroidBundle,
		embeddings: [MusicItemID: [Float]]
	) -> [Song] {
		guard let targetKey = targetBand.bundleKey else { return [] }

		let flat = flatten(bundle: bundle)
		guard !flat.isEmpty else { return [] }

		return songs.filter { song in
			if let emb = embeddings[song.id] {
				return winningBundleKey(embedding: emb, genres: song.genreNames, flat: flat) == targetKey
			}
			return nonEmbeddedSongBelongs(song, target: targetKey, bundle: bundle)
		}
	}

	/// Flattened sub-style entry — one row per (band, sub-style). Built
	/// once per classification pass via `flatten(bundle:)` and reused
	/// across every song so bulk callers (filter + stats) don't pay the
	/// flatten cost on each song.
	typealias FlatEntry = (bandKey: String, payload: EnergyCentroidPayload, token: String)

	static func flatten(bundle: EnergyCentroidBundle) -> [FlatEntry] {
		bundle.bands.flatMap { band, payloads in
			payloads
				.filter { !$0.centroid.isEmpty }
				.map { (band, $0, genreToken(forSlug: $0.subStyle)) }
		}
	}

	/// Single-song band assignment. Returns the band whose centroid (or,
	/// for non-embedded songs, whose sub-style slugs) best matches the
	/// song, or nil if no reliable assignment is possible. Used by the
	/// Library Overview view to bucket every analysis-pool song.
	///
	/// Bulk callers (one call per library song) should flatten once via
	/// `flatten(bundle:)` and pass the result to the `flat:` overload.
	static func band(
		for song: Song,
		embedding: [Float]?,
		bundle: EnergyCentroidBundle?
	) -> EnergyBand? {
		guard let bundle else { return nil }
		return band(
			for: song,
			embedding: embedding,
			bundle: bundle,
			flat: flatten(bundle: bundle)
		)
	}

	static func band(
		for song: Song,
		embedding: [Float]?,
		bundle: EnergyCentroidBundle,
		flat: [FlatEntry]
	) -> EnergyBand? {
		if let emb = embedding, !flat.isEmpty,
		   let key = winningBundleKey(embedding: emb, genres: song.genreNames, flat: flat)
		{
			return EnergyBand.allCases.first { $0.bundleKey == key }
		}
		return firstMatchingBand(forGenres: song.genreNames, bundle: bundle)
	}

	/// Argmax-with-genre-boost across all flattened sub-styles. Returns
	/// the winning band's bundle key, gated by the winning sub-style's
	/// own raw-cosine threshold (the boost helps pick the band; it
	/// shouldn't lower the bar for "did this song match anything").
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

	/// First-match-in-band-order substring fallback for non-embedded
	/// songs. Multiple bands can match an ambiguous tag (e.g. "Classical"
	/// hits glacial *and* mellow); the per-band filter path in
	/// `filterUsingBundledCentroids` checks each band independently, but
	/// for the stats path we have to pick one — band order (glacial →
	/// intense) is the same order the UI surfaces, so a tie there reads
	/// the same way as the chip row.
	private static func firstMatchingBand(
		forGenres genreNames: [String],
		bundle: EnergyCentroidBundle
	) -> EnergyBand? {
		let lowered = genreNames.map { $0.lowercased() }
		for band in EnergyBand.allCases where band != .any {
			guard let key = band.bundleKey, let payloads = bundle.bands[key] else { continue }
			let tokens = payloads.map { genreToken(forSlug: $0.subStyle) }
			if !tokens.isEmpty, lowered.contains(where: { g in tokens.contains(where: g.contains) }) {
				return band
			}
		}
		return nil
	}

	/// Sub-style-granular keyword fallback for the *filter* path —
	/// multi-band overlap is fine here because the filter picks one
	/// band at a time. Distinct from `firstMatchingBand` which has to
	/// commit to a single band for the stats path.
	private static func nonEmbeddedSongBelongs(
		_ song: Song,
		target: String,
		bundle: EnergyCentroidBundle
	) -> Bool {
		guard let payloads = bundle.bands[target] else { return false }
		let tokens = payloads.map { genreToken(forSlug: $0.subStyle) }
		guard !tokens.isEmpty else { return false }
		return song.genreNames.contains { genre in
			let g = genre.lowercased()
			return tokens.contains(where: g.contains)
		}
	}

	/// Sub-style slug → substring-matchable token for Apple genre tags.
	/// Slugs use underscores ("hard_rock", "hip_hop"), Apple uses spaces
	/// or slashes ("Hard Rock", "Hip-Hop/Rap") — we convert underscores
	/// to spaces so substring `.contains` works in either direction.
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
