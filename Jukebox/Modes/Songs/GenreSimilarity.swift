//
//  GenreSimilarity.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Lineage-based genre similarity used by the walk's metadata
//  similarity blend. Pure Jaccard on string-equal genre names treated
//  "Reggae" and "Dub" as wholly unrelated, which blunted the walk on
//  collections with deep stylistic crossover — a deck with reggae,
//  dub, dubstep, and techno tracks got no genre signal bridging the
//  chain even though the chain is sonically obvious.
//
//  Genre lineage is expressed as a set of ordered chains — each chain
//  is a sequence of stylistically descended/adjacent genres. From
//  those chains we materialize n-gram window distances: a bigram
//  (positions i, i+1 in the same chain) scores 0.6, a trigram window
//  (i, i+2) scores 0.3, a 4-gram window (i, i+3) scores 0.1, and
//  anything further apart — or not co-present in any chain — scores
//  0. A direct match (post-normalization) scores 1.0.
//
//  Chains overlap on shared nodes (e.g. "rock" appears in several),
//  so bridging happens implicitly through co-membership. To bridge a
//  pair that doesn't fall within a single chain, add a chain that
//  contains both — it's intentionally local: lineage is named, not
//  inferred via global graph traversal.
//
//  Eventually we may layer a learned model on top — bigram counts
//  from the user's playlists, where co-occurrence is genuine signal
//  rather than my best guess at the music-history textbook — and
//  fall back to these chains when the learned model has too few
//  observations. The chains are the lineage prior.

import Foundation

enum GenreSimilarity {
	/// Soft set similarity between two genre lists in [0, 1]. Each
	/// genre on each side contributes its best match against the
	/// other side, and the running total is averaged over total
	/// membership. With binary 0/1 scores this collapses to the
	/// Sørensen–Dice coefficient; with the graded scores from
	/// `pairwise(_:_:)` it lets closely-related tags earn partial
	/// credit instead of the all-or-nothing Jaccard cliff.
	///
	/// Two empty inputs return 0.5 (neutral, mirroring how the walk
	/// treats missing release dates) so a song with no genre tags
	/// doesn't get punished. One empty side returns 0 — we have
	/// signal on one side and zero overlap on the other.
	static func score(_ aGenres: [String], _ bGenres: [String]) -> Float {
		if aGenres.isEmpty, bGenres.isEmpty { return 0.5 }
		if aGenres.isEmpty || bGenres.isEmpty { return 0 }

		var total: Float = 0
		var count: Float = 0
		for g in aGenres {
			total += bGenres.map { pairwise(g, $0) }.max() ?? 0
			count += 1
		}
		for g in bGenres {
			total += aGenres.map { pairwise(g, $0) }.max() ?? 0
			count += 1
		}
		return total / count
	}

	/// Pairwise similarity between two genre names. 1.0 for exact
	/// (post-normalization) match, then 0.6 / 0.3 / 0.1 by minimum
	/// n-gram window distance across all lineage chains, 0 for
	/// anything further (including unknown genres not in any chain).
	static func pairwise(_ a: String, _ b: String) -> Float {
		let na = normalize(a)
		let nb = normalize(b)
		if na == nb { return 1.0 }
		guard let d = pairwiseDistance[na]?[nb] else { return 0 }
		switch d {
		case 1: return 0.6
		case 2: return 0.3
		case 3: return 0.1
		default: return 0
		}
	}

	// MARK: - Lineage chains

	private static func normalize(_ s: String) -> String {
		s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Ordered lineage chains. Adjacent entries are bigrams; skip-one
	/// is a trigram window; skip-two is a 4-gram window. Chains
	/// overlap on shared ancestors — that's how lineage diverges
	/// from a single 1D ordering. Add new lineage by extending an
	/// existing chain or adding a new one; window distance is
	/// recomputed at static-init time.
	///
	/// All entries are pre-normalized (lowercase, trimmed) so the
	/// adjacency table can key directly without re-normalizing per
	/// lookup.
	private static let chains: [[String]] = [
		// Electronic / dance lineage. The reggae → dub → dubstep →
		// techno chain is the canonical "surprising chain" this
		// exists to enable — kept as a single 5-gram so reggae and
		// techno land within window distance of each other.
		["reggae", "dub", "dubstep", "techno", "house"],
		["electronic", "dub", "dubstep"],
		["electronic", "techno", "edm"],
		["electronic", "house", "deep house"],
		["electronic", "ambient", "idm"],
		["electronic", "ambient", "downtempo"],
		["electronic", "dance"],
		["dance", "house", "disco"],
		["dance", "edm"],
		["dubstep", "drum & bass"],

		// Reggae / ska / dancehall
		["reggae", "ska", "punk"],
		["reggae", "dancehall"],

		// Rock / alternative / indie
		["rock", "alternative", "indie rock", "indie pop"],
		["rock", "garage rock"],
		["rock", "blues", "soul"],
		["alternative", "post-punk", "new wave", "synthpop"],
		["punk", "post-punk", "new wave"],
		["punk", "hardcore punk"],
		["synthpop", "synthwave", "vaporwave"],
		["synthpop", "synthwave", "chillwave"],

		// Metal
		["rock", "hard rock", "metal"],
		["metal", "thrash metal"],
		["metal", "death metal"],
		["metal", "black metal"],
		["metal", "doom metal"],

		// Soul / funk / hip-hop / r&b
		["soul", "funk", "disco", "house"],
		["soul", "r&b/soul", "neo-soul"],
		["soul", "gospel"],
		["r&b/soul", "hip-hop/rap", "rap", "trap"],
		["rap", "lo-fi"],

		// Jazz
		["jazz", "vocal jazz"],
		["jazz", "bebop"],
		["jazz", "fusion", "funk"],
		["jazz", "blues", "soul"],

		// Folk / country / americana
		["folk", "singer/songwriter"],
		["folk", "americana", "bluegrass"],
		["folk", "country", "americana"],

		// Pop bridges
		["pop", "indie pop"],
		["pop", "dance pop", "edm"],
		["pop", "synthpop"],

		// Classical / soundtrack
		["classical", "soundtrack"],
		["classical", "ambient"],
	]

	/// Window cap for n-gram distance. We only consider pairs within
	/// `windowSize - 1` positions of each other in a chain (i.e. a
	/// 4-gram window means up to 3 positions apart). Anything beyond
	/// is "too far" and falls out to 0 — the score curve is steep
	/// enough that a 4th-order link is barely signal anyway.
	private static let windowSize = 4

	/// Precomputed minimum n-gram distance for every co-chain pair.
	/// O(C × L²) build, where C = number of chains and L = chain
	/// length — both small; ~hundreds of entries total. Worth it
	/// to make `pairwise(_:_:)` O(1) inside the walk's N² loop.
	private static let pairwiseDistance: [String: [String: Int]] = {
		var table: [String: [String: Int]] = [:]
		for chain in chains {
			for i in 0 ..< chain.count {
				let upper = min(chain.count, i + windowSize)
				for j in (i + 1) ..< upper {
					let a = chain[i]
					let b = chain[j]
					let d = j - i
					if let existing = table[a]?[b], existing <= d { continue }
					table[a, default: [:]][b] = d
					table[b, default: [:]][a] = d
				}
			}
		}
		return table
	}()
}
