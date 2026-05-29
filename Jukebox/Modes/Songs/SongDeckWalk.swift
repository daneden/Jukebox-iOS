//
//  SongDeckWalk.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Greedy similarity walk that orders a deck so consecutive entries share
//  sonic mood. Cosine over cached AudioFeaturePrint embeddings when
//  available, falling back to genre similarity for un-embedded songs — so
//  a fresh install is still coherent and sharpens as the cache fills.
//
//  Diversity rules (hard-exclude, with graceful relaxation): no same artist
//  within 2 songs, no same album within 3. These break up same-session
//  runs (e.g. five tracks off one album) that pure similarity would stack,
//  since same-album tracks score very close.
//
//  O(N²) similarity comparisons; well under 100ms at N=300.

import Foundation
import MusicKit

enum SongDeckWalk {
	/// Lookback for the same-artist rule: no artist repeats within 3 slots.
	static let artistLookback = 2
	/// Lookback for the same-album rule.
	static let albumLookback = 3
	/// How many top-scored songs the seed is picked from. Wider = more
	/// per-session variety at cold start.
	static let seedTier = 20

	/// Min post-filter candidates for the avoidance seed picker to use the
	/// filtered subset; below this, a one-or-two-song remainder isn't
	/// meaningfully a "different neighbourhood," so fall back to the top tier.
	static let seedAvoidanceFloor = 3

	static func walk(
		songs: [Song],
		embeddings: [MusicItemID: [Float]],
		bpms: [MusicItemID: Double] = [:],
		originals: [MusicItemID: Date] = [:],
		genres: [MusicItemID: [String]] = [:],
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

		// Seed from the top tier, offset by the session seed for variety.
		// An avoid-decade/avoid-artist hint (the previous shuffle's seed)
		// prefers non-matching tier entries — that's how shuffle jumps the
		// walk into a new neighbourhood instead of the same era/artist cluster.
		let tier = min(Self.seedTier, remaining.count)
		let topTier = remaining.prefix(tier)
		let preferred = topTier.enumerated().filter { _, song in
			if let d = avoidDecade, song.releaseDecade(override: originals[song.id]) == d { return false }
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

			// Relax in two steps if no candidates survive: 0 enforces artist
			// + album, 1 drops album, 2 drops both. User-blocked pairs are
			// checked at every level — an explicit "never again" outweighs
			// artist/album smoothing.
			var scored: [(index: Int, score: Float)] = []
			for relaxLevel in 0 ... 2 {
				scored.removeAll(keepingCapacity: true)
				for (i, candidate) in remaining.enumerated() {
					if isBlocked(previous, candidate, in: blockedPairs) { continue }
					if !isEligible(candidate: candidate, history: history, relaxLevel: relaxLevel) {
						continue
					}
					let simPrev = similarity(candidate, previous, embeddings: embeddings, bpms: bpms, originals: originals, genres: genres)
					let score: Float
					if g > 0 {
						let simSeed = similarity(candidate, seedSong, embeddings: embeddings, bpms: bpms, originals: originals, genres: genres)
						score = (1 - g) * simPrev + g * simSeed
					} else {
						score = simPrev
					}
					scored.append((i, score))
				}
				if !scored.isEmpty { break }
			}

			// If every remaining candidate is blocked against `previous`,
			// accept the first rather than deadlock — blocked pairs are a
			// soft preference, not a hard contract.
			let index = scored.isEmpty ? 0 : pickIndex(from: scored, temperature: temperature)
			ordered.append(remaining.remove(at: index))
		}

		return ordered
	}

	/// `temperature == 0` returns the argmax (greedy); positive samples a
	/// softmax so runners-up sometimes win — the "meander" knob.
	private static func pickIndex(
		from candidates: [(index: Int, score: Float)],
		temperature: Double
	) -> Int {
		if temperature <= 0 {
			return candidates.max(by: { $0.score < $1.score })!.index
		}
		let T = Float(temperature)
		// Subtract the max before exp() for numerical stability.
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

		// index 0 = most recent placement.
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

	/// Blended similarity. AudioFeaturePrint clusters by coarse acoustic
	/// texture but bunches pairwise cosine into a narrow ~0.80–0.94 band,
	/// too tight for the walk to act on alone. We blend in metadata: era
	/// (heavy, because the embedding flattens decades — without it the walk
	/// pairs 1940s jazz with modern electronic that shares "vocals +
	/// rhythm"), genre (from `GenreStore`, since `Song.genreNames` is empty
	/// on library songs; un-warmed pairs score neutral), and a tempo term
	/// when both sides have BPM cached (partial coverage; pairs without it
	/// take the no-BPM blend). Tunable.
	static func similarity(
		_ a: Song,
		_ b: Song,
		embeddings: [MusicItemID: [Float]],
		bpms: [MusicItemID: Double] = [:],
		originals: [MusicItemID: Date] = [:],
		genres: [MusicItemID: [String]] = [:]
	) -> Float {
		let genre = GenreSimilarity.score(genres[a.id] ?? [], genres[b.id] ?? [])
		let era = eraProximity(a, b, originals: originals)

		if let eA = embeddings[a.id], let eB = embeddings[b.id] {
			let cosine = AudioEmbeddingService.cosineSimilarity(eA, eB)
			if let bA = bpms[a.id], let bB = bpms[b.id] {
				let tempo = bpmProximity(bA, bB)
				// Weights sum to 1; era stays heavy to police cross-decade jumps.
				return 0.35 * cosine + 0.20 * tempo + 0.20 * genre + 0.25 * era
			}
			return 0.4 * cosine + 0.25 * genre + 0.35 * era
		}
		// Metadata only when either side lacks an embedding.
		return 0.5 * genre + 0.5 * era
	}

	/// Tempo similarity in [0, 1], octave-folded so 2×/½× pairs (70 vs 140)
	/// read as the same pulse. Exponential decay, ~30 BPM half-life.
	private static func bpmProximity(_ a: Double, _ b: Double) -> Float {
		let direct = abs(a - b)
		let doubled = abs(a - 2 * b)
		let halved = abs(a - b / 2)
		let diff = min(direct, doubled, halved)
		return Float(exp(-diff / 30.0))
	}

	/// Exponential decay, ~20-year half-life. Exponential (not linear
	/// clamping) so it keeps dropping past 30y — clamping scored both 30y
	/// and 80y gaps as 0.0, letting cosine-bunched cross-era pairs sneak
	/// adjacent. Missing release date → neutral 0.5.
	///
	/// `originals` carries the `OriginalReleaseStore` date so remasters and
	/// compilations score against first release; cold songs use `releaseDate`.
	private static func eraProximity(
		_ a: Song,
		_ b: Song,
		originals: [MusicItemID: Date]
	) -> Float {
		let aDate = originals[a.id] ?? a.releaseDate
		let bDate = originals[b.id] ?? b.releaseDate
		guard let aDate, let bDate else { return 0.5 }
		let yearsApart = abs(aDate.timeIntervalSince(bDate)) / (365.25 * 86400)
		return Float(exp(-yearsApart / 20))
	}
}

extension Song {
	/// Decade of release (1960, 1970, …). Nil when MusicKit has no release
	/// date, common for library-only items.
	var releaseDecade: Int? {
		releaseDecade(override: nil)
	}

	/// Override-aware variant. `override` is the `OriginalReleaseStore` date
	/// (catches remasters/compilations whose own `releaseDate` is the
	/// reissue year); falls back to `releaseDate`.
	func releaseDecade(override: Date?) -> Int? {
		guard let date = override ?? releaseDate else { return nil }
		let year = Calendar.current.component(.year, from: date)
		return (year / 10) * 10
	}
}
