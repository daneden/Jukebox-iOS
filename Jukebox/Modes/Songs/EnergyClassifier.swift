//
//  EnergyClassifier.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Centroid-based refinement for the "Energy" walk-control band. Genre
//  keywords alone classify too coarsely — Apple's "Pop" can mean both
//  glacial ambient-adjacent art-pop and bouncy K-pop. We use those
//  keywords as a seed set (anchors), mean-pool their cached
//  `AudioFeaturePrint` embeddings to produce a per-band centroid, then
//  rank the wider pool by cosine to that centroid.
//
//  Caveat: `AudioFeaturePrint` empirically bunches pairwise cosine
//  into a narrow 0.80–0.94 band (see SongDeckWalk.similarity), so an
//  absolute threshold doesn't generalise. Instead we self-calibrate:
//  the median cosine of each anchor to the centroid becomes the
//  threshold. A "tight" band (low intra-anchor variance, e.g.
//  classical) gets a high threshold; a broad one (mellow, which
//  spans pop / soul / jazz / soft rock) gets a low one. Songs
//  without a cached embedding still appear if they match the seed
//  keywords — so a fresh install with zero embeddings cached
//  degrades gracefully to keyword-only behaviour.
//

import Foundation
import MusicKit

enum EnergyClassifier {
	/// Minimum anchor count required to trust a centroid. Below this
	/// the centroid is noise — bail and let the caller fall back to
	/// the keyword filter. Picked low so small libraries still see
	/// some embedding-aware filtering.
	static let minAnchors = 5

	/// Returns the subset of `songs` that belong in `band`, or nil
	/// when the band is `.any` or we don't have enough anchors with
	/// cached embeddings to build a reliable centroid. nil signals
	/// the caller to soft-fall-back to the keyword filter.
	static func filter(
		_ songs: [Song],
		band: EnergyBand,
		embeddings: [MusicItemID: [Float]]
	) -> [Song]? {
		guard let keywords = band.genreKeywords else { return nil }

		// Anchors = songs whose genreNames match the band's seed
		// keywords. The keyword-matching logic is intentionally the
		// same as the standalone keyword filter so the two stay in
		// sync if either is tuned.
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

		// Self-calibrating threshold: median anchor-to-centroid
		// cosine. Roughly half the anchors clear it by construction;
		// non-anchor pool songs that sound "as close" to the band as
		// the typical anchor get pulled in.
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
