//
//  GenreSimilarity.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Hand-curated genre adjacency graph used by the walk's metadata
//  similarity blend. Pure Jaccard on string-equal genre names treated
//  "Reggae" and "Dub" as wholly unrelated, which blunted the walk on
//  collections with deep stylistic crossover — a deck with reggae,
//  dub, dubstep, and techno tracks got no genre signal bridging the
//  chain even though the chain is sonically obvious.
//
//  Genres are nodes in a small undirected graph; pairwise similarity
//  decays with shortest-path distance — 1-hop neighbours score 0.6,
//  2-hop 0.3, 3-hop 0.1, anything further 0. The decay curve is steep
//  enough that a direct match (1.0) still dominates a cousin (0.3),
//  but a "reggae → techno" pair earns a small bridging score that the
//  rest of the blend can build on instead of starting from zero.
//
//  The graph is intentionally sparse — only edges that capture
//  meaningful family or lineage relationships, not "both are music."
//  Apple Music's genre tags use both broad labels ("Rock",
//  "Electronic") and finer sub-genres ("Dubstep", "Trap"); the graph
//  includes both and bridges them, so e.g. "Reggae" / "Dub" scores
//  like a direct lineage step rather than two unrelated strings.

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
	/// (post-normalization) match, then 0.6 / 0.3 / 0.1 by graph
	/// distance, 0 for anything further (including unknown genres
	/// not in the graph).
	static func pairwise(_ a: String, _ b: String) -> Float {
		let na = normalize(a)
		let nb = normalize(b)
		if na == nb { return 1.0 }
		guard let distance = shortestPath(from: na, to: nb, maxDepth: 3) else {
			return 0
		}
		switch distance {
		case 1: return 0.6
		case 2: return 0.3
		case 3: return 0.1
		default: return 0
		}
	}

	// MARK: - Graph

	private static func normalize(_ s: String) -> String {
		s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Undirected edges. Listed once; `adjacency` mirrors them. Add new
	/// relationships here — keep edges meaningful (lineage, sonic
	/// kinship, named sub-genre) rather than thematic.
	private static let edges: [(String, String)] = [
		// Electronic / dance lineage. The reggae → dub → dubstep →
		// drum-and-bass → techno → house spine is the canonical
		// "surprising chain" this graph exists to enable.
		("electronic", "dance"),
		("electronic", "house"),
		("electronic", "techno"),
		("electronic", "ambient"),
		("electronic", "edm"),
		("electronic", "idm"),
		("house", "techno"),
		("house", "deep house"),
		("house", "disco"),
		("techno", "edm"),
		("techno", "dubstep"),
		("dubstep", "drum & bass"),
		("dubstep", "dub"),
		("ambient", "downtempo"),
		("ambient", "idm"),
		("ambient", "chillwave"),

		// Reggae lineage
		("reggae", "dub"),
		("reggae", "ska"),
		("reggae", "dancehall"),
		("ska", "punk"),

		// Rock family
		("rock", "alternative"),
		("rock", "indie rock"),
		("rock", "hard rock"),
		("rock", "garage rock"),
		("rock", "blues"),
		("alternative", "indie rock"),
		("alternative", "post-punk"),
		("alternative", "indie pop"),
		("indie rock", "indie pop"),
		("punk", "post-punk"),
		("punk", "hardcore punk"),
		("punk", "new wave"),
		("post-punk", "new wave"),
		("new wave", "synthpop"),
		("synthpop", "pop"),
		("synthpop", "synthwave"),
		("synthwave", "vaporwave"),
		("synthwave", "chillwave"),

		// Metal
		("hard rock", "metal"),
		("metal", "thrash metal"),
		("metal", "death metal"),
		("metal", "black metal"),
		("metal", "doom metal"),

		// Hip-hop / R&B / soul / funk
		("hip-hop/rap", "rap"),
		("hip-hop/rap", "trap"),
		("hip-hop/rap", "r&b/soul"),
		("rap", "trap"),
		("rap", "lo-fi"),
		("r&b/soul", "soul"),
		("r&b/soul", "neo-soul"),
		("r&b/soul", "funk"),
		("soul", "funk"),
		("soul", "gospel"),
		("soul", "blues"),
		("funk", "disco"),
		("disco", "dance"),

		// Jazz
		("jazz", "vocal jazz"),
		("jazz", "bebop"),
		("jazz", "fusion"),
		("jazz", "blues"),
		("jazz", "soul"),
		("fusion", "funk"),

		// Folk / country / americana
		("folk", "singer/songwriter"),
		("folk", "americana"),
		("folk", "country"),
		("country", "americana"),
		("country", "bluegrass"),
		("americana", "bluegrass"),
		("americana", "singer/songwriter"),

		// Pop bridges
		("pop", "indie pop"),
		("pop", "dance pop"),
		("dance pop", "edm"),
		("dance pop", "dance"),

		// Classical / score
		("classical", "soundtrack"),
		("classical", "ambient"),
	]

	private static let adjacency: [String: Set<String>] = {
		var adj: [String: Set<String>] = [:]
		for (a, b) in edges {
			adj[a, default: []].insert(b)
			adj[b, default: []].insert(a)
		}
		return adj
	}()

	/// Returns shortest-path hop count from `start` to `goal`, or `nil`
	/// if there's no path within `maxDepth` hops. Plain BFS; graph is
	/// small (~40 nodes, ~80 edges) so each call is microseconds.
	private static func shortestPath(
		from start: String,
		to goal: String,
		maxDepth: Int
	) -> Int? {
		guard adjacency[start] != nil, adjacency[goal] != nil else { return nil }

		var visited: Set<String> = [start]
		var frontier: Set<String> = [start]

		for depth in 1 ... maxDepth {
			var next: Set<String> = []
			for node in frontier {
				guard let neighbours = adjacency[node] else { continue }
				for n in neighbours where !visited.contains(n) {
					if n == goal { return depth }
					visited.insert(n)
					next.insert(n)
				}
			}
			if next.isEmpty { return nil }
			frontier = next
		}
		return nil
	}
}
