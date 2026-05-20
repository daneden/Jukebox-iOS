//
//  SongDeckWalk.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Greedy similarity walk that orders a deck of songs so consecutive
//  entries share sonic mood. Uses cached AudioFeaturePrint embeddings
//  via cosine similarity when available, falling back to genre Jaccard
//  for songs that haven't been embedded yet — so the walk produces a
//  coherent ordering on a fresh install (zero embeddings cached) and
//  gradually sharpens as the embedding cache fills via background work.
//
//  Diversity rules (hard-exclude, with graceful relaxation):
//   - No same artist within the previous 2 songs.
//   - No same album within the previous 3 songs.
//  These break up "5 Sgt. Pepper tracks in a row" runs that pure
//  similarity would produce — sonically those tracks are very close
//  (they came out of the same session at the same studio) and a
//  greedy walk would happily stack them.
//
//  Complexity: O(N²) similarity comparisons where N = deck size.
//  For N=300 that's 45,000 pairs × a few hundred multiplies each;
//  well under 100ms on-device.

import Foundation
import MusicKit

enum SongDeckWalk {
	/// Lookback for the same-artist rule. Two means "no artist may repeat
	/// in three consecutive slots."
	static let artistLookback = 2
	/// Lookback for the same-album rule.
	static let albumLookback = 3
	/// How many of the top-scored songs the walk picks its seed from.
	/// Wider = more per-session variety at cold start; the same 10 high-
	/// scorers were cycling too predictably at 10.
	static let seedTier = 20

	static func walk(
		songs: [Song],
		embeddings: [MusicItemID: [Float]],
		seed: UInt64
	) -> [Song] {
		guard songs.count > 1 else { return songs }

		var remaining = songs
		var ordered: [Song] = []
		ordered.reserveCapacity(songs.count)

		// Seed from the top of the score-ranked input but offset by the
		// session seed so different launches start the walk in different
		// places.
		let tier = min(Self.seedTier, remaining.count)
		let seedIdx = Int(seed % UInt64(tier))
		ordered.append(remaining.remove(at: seedIdx))

		while !remaining.isEmpty {
			let previous = ordered.last!
			let history = Array(ordered.suffix(max(artistLookback, albumLookback)))

			// Try strict rules first; relax in two steps if no candidates
			// survive. relaxLevel=0 enforces both artist and album; =1
			// drops album; =2 drops both (pure similarity pick).
			var picked: (index: Int, similarity: Float)?
			for relaxLevel in 0 ... 2 {
				for (i, candidate) in remaining.enumerated() {
					if !isEligible(candidate: candidate, history: history, relaxLevel: relaxLevel) {
						continue
					}
					let sim = similarity(candidate, previous, embeddings: embeddings)
					if picked == nil || sim > picked!.similarity {
						picked = (i, sim)
					}
				}
				if picked != nil { break }
			}

			// `picked` is guaranteed at relaxLevel=2 (no rules); the force-
			// unwrap is safe as long as `remaining.isEmpty` was false on
			// the loop guard.
			ordered.append(remaining.remove(at: picked!.index))
		}

		return ordered
	}

	private static func isEligible(
		candidate: Song,
		history: [Song],
		relaxLevel: Int
	) -> Bool {
		if relaxLevel >= 2 { return true }

		// Walk back through history; index 0 = most recent placement.
		let recent = Array(history.reversed())
		for (i, prev) in recent.enumerated() {
			if i < artistLookback, candidate.artistName == prev.artistName {
				return false
			}
			if relaxLevel == 0, i < albumLookback {
				if let candAlbum = nonEmpty(candidate.albumTitle),
				   let prevAlbum = nonEmpty(prev.albumTitle),
				   candAlbum == prevAlbum
				{
					return false
				}
			}
		}
		return true
	}

	private static func nonEmpty(_ s: String?) -> String? {
		guard let s, !s.isEmpty else { return nil }
		return s
	}

	/// Blended similarity score. AudioFeaturePrint is a general-purpose
	/// sound classifier — it clusters strongly by coarse acoustic texture
	/// (timbre/instrumentation/"is this a song with vocals + rhythm")
	/// but discriminates weakly between genres and eras *within* that
	/// broad cluster. Empirically, on diverse-but-vocal samples it bunches
	/// pairwise cosine into a narrow 0.80–0.94 band that the walk can't
	/// use to make meaningful next-song decisions.
	///
	/// We compensate by blending the cosine with metadata signals we have
	/// at near-total coverage (genre 99.9%, releaseDate close to 100%).
	/// Weights chosen to give the embedding the largest single share
	/// while leaving enough room for metadata to break ties when the
	/// embedding can't (e.g. classic R&B vs modern electronic that both
	/// have "vocals + rhythm" texture).
	///
	/// Tunable; revisit after the walk's been used in anger.
	static func similarity(
		_ a: Song,
		_ b: Song,
		embeddings: [MusicItemID: [Float]]
	) -> Float {
		let genre = genreJaccard(a, b)
		let era = eraProximity(a, b)

		if let eA = embeddings[a.id], let eB = embeddings[b.id] {
			let cosine = AudioEmbeddingService.cosineSimilarity(eA, eB)
			return 0.5 * cosine + 0.3 * genre + 0.2 * era
		}
		// No cached embedding for at least one side — metadata only.
		return 0.6 * genre + 0.4 * era
	}

	private static func genreJaccard(_ a: Song, _ b: Song) -> Float {
		let aGenres = Set(a.genreNames)
		let bGenres = Set(b.genreNames)
		let union = aGenres.union(bGenres)
		guard !union.isEmpty else { return 0.5 }
		return Float(aGenres.intersection(bGenres).count) / Float(union.count)
	}

	/// Linear decay from 1.0 at zero years apart to 0.0 at ≥30 years.
	/// Songs without a release date get a neutral 0.5 — we don't punish
	/// missing data, just don't reward it.
	///
	/// Known limitation: remasters (e.g. "Sgt Pepper 2017 Mix") inherit
	/// the remaster's release date, not the original recording's. The
	/// 0.2 weight on era keeps that mistake from dominating the blend.
	private static func eraProximity(_ a: Song, _ b: Song) -> Float {
		guard let aDate = a.releaseDate, let bDate = b.releaseDate else {
			return 0.5
		}
		let yearsApart = abs(aDate.timeIntervalSince(bDate)) / (365.25 * 86400)
		return max(0, 1 - Float(yearsApart) / 30)
	}
}
