//
//  GenreSimilarity.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Lineage-based genre similarity for the walk's metadata blend. Pure
//  Jaccard on string-equal genre names treated "Reggae" and "Dub" as
//  unrelated, blunting the walk on collections with deep stylistic
//  crossover (reggae→dub→dubstep→techno got no bridging signal).
//
//  Lineage is a set of ordered chains of stylistically descended /
//  adjacent genres. From them we materialize n-gram window distances:
//  a bigram (i, i+1) scores 0.6, a trigram window (i, i+2) 0.3, a
//  4-gram (i, i+3) 0.1, anything further or off-chain 0; a direct
//  match (post-normalization) scores 1.0. Chains overlap on shared
//  nodes, so bridging happens through co-membership — to bridge a pair
//  in no single chain, add one containing both. Lineage is named, not
//  inferred by global graph traversal.
//
//  Genre strings track Apple's genre code table — what
//  `Song.genreNames` returns. Apple's slash-combined tokens
//  ("Jungle/Drum'n'bass", "Death Metal/Black Metal") are kept intact.
//  A few third-party tags ("synth-pop", "post-punk", "trip-hop") are
//  included as transitive bridges for iTunes Match / Bandcamp imports.

import Foundation

enum GenreSimilarity {
	/// Soft set similarity between two genre lists in [0, 1]. Each genre
	/// contributes its best match against the other side, averaged over
	/// total membership — Sørensen–Dice with graded `pairwise` scores so
	/// related tags earn partial credit instead of the Jaccard cliff.
	///
	/// MusicKit returns a literal "Music" companion on nearly every song;
	/// a pairwise "Music" match would inject ~+0.5 phantom similarity
	/// everywhere, so it's stripped before scoring.
	///
	/// Both-empty (after stripping) returns 0.5 (neutral, mirroring how
	/// the walk treats missing release dates); one-empty returns 0.
	static func score(_ aGenres: [String], _ bGenres: [String]) -> Float {
		let a = stripPhantoms(aGenres)
		let b = stripPhantoms(bGenres)
		if a.isEmpty, b.isEmpty { return 0.5 }
		if a.isEmpty || b.isEmpty { return 0 }

		var total: Float = 0
		var count: Float = 0
		for g in a {
			total += b.map { pairwise(g, $0) }.max() ?? 0
			count += 1
		}
		for g in b {
			total += a.map { pairwise(g, $0) }.max() ?? 0
			count += 1
		}
		return total / count
	}

	/// Pairwise similarity between two genre names. 1.0 for exact
	/// (post-normalization) match, then 0.6 / 0.3 / 0.1 by minimum n-gram
	/// window distance across chains, 0 for anything further or off-chain.
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

	// MARK: - Normalization

	private static func normalize(_ s: String) -> String {
		s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Companion strings MusicKit attaches that carry no lineage signal —
	/// "Music" is present on nearly every track. Listed normalized.
	private static let phantoms: Set<String> = ["music"]

	private static func stripPhantoms(_ genres: [String]) -> [String] {
		genres.filter { !phantoms.contains(normalize($0)) }
	}

	// MARK: - Lineage chains

	/// Ordered lineage chains. Adjacent = bigram, skip-one = trigram
	/// window, skip-two = 4-gram. Chains overlap on shared ancestors so
	/// lineage isn't a single 1D ordering. Entries are pre-normalized
	/// (lowercase, trimmed) so the adjacency table keys directly. Apple's
	/// slash-combined tokens are kept whole — that's what MusicKit returns.
	private static let chains: [[String]] = [
		// MARK: Electronic / Dance

		// Apple splits House/Techno/Trance under Dance and keeps
		// Dubstep/Ambient/IDM/Industrial under Electronic; chains bridge
		// the two top-level genres via shared descendants.
		["disco", "post-disco", "house", "techno"],
		["funk", "disco", "house"],
		["electronic", "dance", "house"],
		["electronic", "dance", "techno"],
		["electronic", "dance", "trance"],
		["house", "techno", "trance"],
		["techno", "industrial"],
		["electronica", "idm/experimental"],
		["electronic", "ambient", "downtempo"],
		["ambient", "idm/experimental"],
		// Jungle/DnB and Dubstep both descend from UK breakbeat / garage.
		["breakbeat", "jungle/drum'n'bass", "dubstep"],
		["garage", "jungle/drum'n'bass", "dubstep"],
		["dubstep", "bass"],

		// MARK: Reggae lineage — the surprising-chain spine

		// Ska → Reggae → Dub. Apple has no "Rocksteady" tag so that link
		// is elided. Dub → Dubstep and Dub → Jungle/DnB are both real.
		["ska", "reggae", "roots reggae"],
		["reggae", "dub", "dubstep"],
		["reggae", "dub", "jungle/drum'n'bass"],
		["reggae", "dancehall", "modern dancehall"],
		["reggae", "lovers rock"],
		// Reggaetón surfaces as "Latin Urban" (English storefront) or
		// "Urbano latino" (Latin storefront); both can appear, so bridge.
		["dancehall", "modern dancehall", "latin urban"],
		["latin urban", "urbano latino"],
		// 5-gram bridging reggae to electronic. Dubstep→Techno is the
		// contested step (shared UK ancestry + crossover) but worth the
		// bridge.
		["reggae", "dub", "dubstep", "techno", "house"],

		// MARK: Rock / Alternative / Indie / Punk / Wave

		// Apple keeps Punk / New Wave / Indie / Grunge / Goth / Pop Punk /
		// EMO under Alternative; the heavier rock + metal subgenres under
		// Rock.
		["rock & roll", "rock", "hard rock"],
		["rock", "psychedelic", "hard rock"],
		["rock", "blues-rock", "hard rock"],
		["alternative", "indie rock", "indie pop"],
		["alternative", "college rock", "indie rock"],
		["alternative", "grunge"],
		["alternative", "goth rock"],
		["punk", "new wave"],
		// "post-punk"/"synth-pop" aren't Apple tags but appear on iTunes
		// Match imports; kept as bridges from Punk → New Wave.
		["punk", "post-punk", "new wave"],
		["new wave", "synth-pop"],
		["indie pop", "pop punk", "emo"],
		["psychedelic", "prog-rock/art rock"],

		// MARK: Metal

		["hard rock", "heavy metal", "metal"],
		["heavy metal", "death metal/black metal"],
		["metal", "hair metal", "glam rock"],

		// MARK: Hip-Hop / R&B / Soul / Funk / Disco

		// Soul → Funk → Disco → House is the Black-American dance-music
		// spine; hip-hop emerged from funk + disco sampling.
		["soul", "funk", "disco"],
		["soul", "neo-soul"],
		["funk", "disco", "house"],
		["funk", "hip-hop/rap"],
		["disco", "hip-hop/rap"],
		["r&b/soul", "hip-hop/rap"],
		["hip-hop/rap", "rap", "hip-hop"],
		["hip-hop/rap", "alternative rap", "underground rap"],
		["hip-hop/rap", "gangsta rap", "dirty south"],
		["motown", "soul", "r&b/soul"],
		["contemporary r&b", "neo-soul"],
		// Doo Wop is a live Apple tag; bridge to the R&B/Soul spine so it
		// reads as mellow rather than unknown.
		["doo wop", "r&b/soul", "soul"],
		// Trip-hop isn't an Apple tag; Bristol acts surface as Downtempo.
		// Bridge downtempo to hip-hop so dub/downtempo connects to rap.
		["dub", "downtempo", "hip-hop/rap"],

		// MARK: Jazz / Blues / Gospel

		["blues", "soul"],
		["blues", "rock", "blues-rock"],
		["jazz", "fusion", "funk"],
		["jazz", "bop", "hard bop"],
		["jazz", "cool jazz", "smooth jazz"],
		["jazz", "vocal jazz"],
		["jazz", "latin jazz"],
		["jazz", "big band"],
		["soul", "gospel"],
		["country gospel", "gospel"],

		// MARK: Folk / Country / Americana / Bluegrass

		["folk", "traditional folk", "contemporary folk"],
		["folk", "folk-rock"],
		["country", "traditional country", "bluegrass"],
		["country", "bluegrass", "americana"],
		["country", "americana", "alternative country"],
		["singer/songwriter", "folk-rock", "alternative folk"],
		["country", "honky tonk", "outlaw country"],

		// MARK: Pop bridges

		// Apple has no "Dance Pop" tag; bridge via Disco → Pop.
		["pop", "adult contemporary", "soft rock"],
		["pop", "teen pop", "k-pop"],
		["pop", "britpop", "indie pop"],
		["pop", "pop/rock", "rock"],
		["disco", "pop"],
		["pop", "synth-pop"],

		// MARK: Latin

		// Latin Jazz overlaps the Jazz family.
		["latin", "pop latino", "urbano latino"],
		["latin", "salsa y tropical", "música tropical"],
		["latin", "latin jazz"],
		["latin", "música mexicana"],

		// MARK: Classical / Soundtrack

		["classical", "soundtrack", "original score"],
		["classical", "ambient"],
	]

	/// Window cap for n-gram distance: pairs within `windowSize - 1`
	/// positions in a chain count, anything beyond falls to 0.
	private static let windowSize = 4

	/// Precomputed minimum n-gram distance for every co-chain pair, so
	/// `pairwise(_:_:)` is O(1) inside the walk's N² loop.
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
