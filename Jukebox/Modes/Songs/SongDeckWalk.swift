//
//  SongDeckWalk.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Greedy similarity walk that orders a deck of songs so consecutive
//  entries share sonic mood. Uses cached AudioFeaturePrint embeddings
//  via cosine similarity when available, falling back to a graph-based
//  genre similarity for songs that haven't been embedded yet — so the
//  walk produces a coherent ordering on a fresh install (zero
//  embeddings cached) and gradually sharpens as the embedding cache
//  fills via background work.
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

	/// Minimum number of post-filter candidates required for the
	/// neighbourhood-avoidance seed picker to use the filtered subset.
	/// Below this we accept the unfiltered top tier — a one-or-two-song
	/// remainder isn't meaningfully a "different neighbourhood."
	static let seedAvoidanceFloor = 3

	static func walk(
		songs: [Song],
		embeddings: [MusicItemID: [Float]],
		bpms: [MusicItemID: Double] = [:],
		blockedPairs: Set<String> = [],
		seed: UInt64,
		controls: WalkControls = .default,
		avoidDecade: Int? = nil,
		avoidArtist: String? = nil
	) -> [Song] {
		guard songs.count > 1 else { return songs }

		var remaining = songs
		var ordered: [Song] = []
		ordered.reserveCapacity(songs.count)

		// Seed from the top of the score-ranked input but offset by the
		// session seed so different launches start the walk in different
		// places. When the caller provides an avoid-decade/avoid-artist
		// hint (the previous shuffle's seed), prefer tier entries that
		// don't match — that's how the shuffle button reliably jumps
		// the walk into a new neighbourhood instead of grinding through
		// the same era/artist cluster.
		let tier = min(Self.seedTier, remaining.count)
		let topTier = remaining.prefix(tier)
		let preferred = topTier.enumerated().filter { _, song in
			if let d = avoidDecade, song.releaseDecade == d { return false }
			if let a = avoidArtist, song.artistName == a { return false }
			return true
		}
		let candidates = preferred.count >= Self.seedAvoidanceFloor
			? Array(preferred)
			: Array(topTier.enumerated())
		let pick = candidates[Int(seed % UInt64(candidates.count))]
		ordered.append(remaining.remove(at: pick.offset))

		let g = Float(controls.seedGravity)
		let temperature = controls.stepTemperature
		let seedSong = ordered[0]

		while !remaining.isEmpty {
			let previous = ordered.last!
			let history = Array(ordered.suffix(max(artistLookback, albumLookback)))

			// Try strict rules first; relax in two steps if no candidates
			// survive. relaxLevel=0 enforces both artist and album; =1
			// drops album; =2 drops both (pure similarity pick).
			//
			// User-blocked pairs are checked at every relax level — they
			// represent an explicit "never again" signal, so we'd rather
			// violate artist/album smoothing than recreate a pairing the
			// user already rejected.
			var scored: [(index: Int, score: Float)] = []
			for relaxLevel in 0 ... 2 {
				scored.removeAll(keepingCapacity: true)
				for (i, candidate) in remaining.enumerated() {
					if isBlocked(previous, candidate, in: blockedPairs) { continue }
					if !isEligible(candidate: candidate, history: history, relaxLevel: relaxLevel) {
						continue
					}
					let simPrev = similarity(candidate, previous, embeddings: embeddings, bpms: bpms)
					let score: Float
					if g > 0 {
						let simSeed = similarity(candidate, seedSong, embeddings: embeddings, bpms: bpms)
						score = (1 - g) * simPrev + g * simSeed
					} else {
						score = simPrev
					}
					scored.append((i, score))
				}
				if !scored.isEmpty { break }
			}

			// Fallback: the blocked-pair filter is strict, so it's
			// theoretically possible for every remaining candidate to be
			// blocked against `previous`. Rather than deadlocking the
			// walk, accept the first remaining song — blocked pairs are
			// a soft preference, not a hard contract, and an N=300 deck
			// would have to be extraordinarily blocked for this branch
			// to fire in practice.
			let index = scored.isEmpty ? 0 : pickIndex(from: scored, temperature: temperature)
			ordered.append(remaining.remove(at: index))
		}

		return ordered
	}

	/// `temperature == 0` returns the argmax (greedy, deterministic).
	/// Positive temperature samples from a softmax over the scored
	/// candidates, so the runner-up sometimes wins — this is the
	/// "meander" knob from the walk-controls popover.
	private static func pickIndex(
		from candidates: [(index: Int, score: Float)],
		temperature: Double
	) -> Int {
		if temperature <= 0 {
			return candidates.max(by: { $0.score < $1.score })!.index
		}
		let T = Float(temperature)
		// Subtract the max before exp() — keeps numbers in a sane range
		// even when scores are bunched (which they often are after the
		// metadata-blend bunches cosine into a narrow band).
		let maxScore = candidates.map(\.score).max() ?? 0
		let weights = candidates.map { exp(($0.score - maxScore) / T) }
		let total = weights.reduce(0, +)
		guard total > 0 else {
			return candidates.max(by: { $0.score < $1.score })!.index
		}
		var r = Float.random(in: 0 ..< total)
		for (cand, w) in zip(candidates, weights) {
			r -= w
			if r <= 0 { return cand.index }
		}
		return candidates.last!.index
	}

	private static func isBlocked(
		_ a: Song,
		_ b: Song,
		in pairs: Set<String>
	) -> Bool {
		guard !pairs.isEmpty else { return false }
		return pairs.contains(TransitionFeedbackStore.pairKey(a.id.rawValue, b.id.rawValue))
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
	/// at near-total coverage (genre 99.9%, releaseDate close to 100%)
	/// and — when both sides have BPM cached — a tempo-proximity term
	/// that captures the rhythmic dimension the timbral embedding
	/// flattens. BPM coverage is partial (legacy embeddings have nil
	/// BPM, ambient/classical defeats the detector), so pairs without
	/// it fall through to the no-BPM blend.
	///
	/// Era is weighted heavily because the embedding flattens decades —
	/// without it, the walk happily pairs e.g. 1940s vocal-jazz with
	/// modern electronic that happens to share "vocals + rhythm"
	/// texture. Combined with the exponential decay in `eraProximity`,
	/// a 50+ year gap is penalised hard enough that the walk needs an
	/// unusually strong cosine + genre case to bridge it.
	///
	/// Tunable; revisit after the walk's been used in anger.
	static func similarity(
		_ a: Song,
		_ b: Song,
		embeddings: [MusicItemID: [Float]],
		bpms: [MusicItemID: Double] = [:]
	) -> Float {
		let genre = GenreSimilarity.score(a.genreNames, b.genreNames)
		let era = eraProximity(a, b)

		if let eA = embeddings[a.id], let eB = embeddings[b.id] {
			let cosine = AudioEmbeddingService.cosineSimilarity(eA, eB)
			if let bA = bpms[a.id], let bB = bpms[b.id] {
				let tempo = bpmProximity(bA, bB)
				// 0.35 cos + 0.20 tempo + 0.20 genre + 0.25 era.
				// Cosine keeps the most weight, era stays heavy to
				// police cross-decade jumps, and tempo + genre share
				// what's left. Sums to 1.00.
				return 0.35 * cosine + 0.20 * tempo + 0.20 * genre + 0.25 * era
			}
			return 0.4 * cosine + 0.25 * genre + 0.35 * era
		}
		// No cached embedding for at least one side — metadata only.
		return 0.5 * genre + 0.5 * era
	}

	/// Tempo similarity in [0, 1] with octave folding. A 70 BPM ballad
	/// and a 140 BPM rock track share the same pulse subdivision, so
	/// pairs at 2× / ½× the detected BPM are treated as identical
	/// rhythmically. Exponential decay with a ~30 BPM half-life: 0
	/// diff → 1.0, 30 → 0.37, 60 → 0.14.
	private static func bpmProximity(_ a: Double, _ b: Double) -> Float {
		let direct = abs(a - b)
		let doubled = abs(a - 2 * b)
		let halved = abs(a - b / 2)
		let diff = min(direct, doubled, halved)
		return Float(exp(-diff / 30.0))
	}

	/// Exponential decay with a ~20-year halflife. Linear clamping at 30
	/// years stopped distinguishing between "kind of distant" (e.g. 30y)
	/// and "wildly distant" (80y) — both produced an era score of 0.0,
	/// which let cosine-bunched cross-era pairs (1940s vocal-jazz vs
	/// 2020s electronic) sneak adjacent in the walk. Exponential keeps
	/// dropping past 30y so a half-century gap is meaningfully worse
	/// than a generation gap.
	///
	/// Sample values: 0y → 1.00, 10y → 0.61, 20y → 0.37, 30y → 0.22,
	/// 50y → 0.08, 80y → 0.02.
	///
	/// Songs without a release date get a neutral 0.5 — we don't punish
	/// missing data, just don't reward it.
	///
	/// Known limitation: remasters (e.g. "Sgt Pepper 2017 Mix") inherit
	/// the remaster's release date, not the original recording's. Era's
	/// 0.35 weight keeps that mistake from dominating the blend on its
	/// own, but back-to-back remasters of decades-apart originals will
	/// still register as same-era.
	private static func eraProximity(_ a: Song, _ b: Song) -> Float {
		guard let aDate = a.releaseDate, let bDate = b.releaseDate else {
			return 0.5
		}
		let yearsApart = abs(aDate.timeIntervalSince(bDate)) / (365.25 * 86400)
		return Float(exp(-yearsApart / 20))
	}
}

extension Song {
	/// Decade of release as an Int (1960, 1970, ..., 2020). Nil when
	/// MusicKit has no release date — common for library-only items
	/// and tracks with missing metadata. Used by the walk's shuffle-
	/// neighbourhood avoidance.
	var releaseDecade: Int? {
		guard let date = releaseDate else { return nil }
		let year = Calendar.current.component(.year, from: date)
		return (year / 10) * 10
	}
}
