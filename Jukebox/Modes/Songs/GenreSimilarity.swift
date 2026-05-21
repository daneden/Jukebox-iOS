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
//  Genre strings track Apple's iTunes/Apple Music genre code table —
//  the strings MusicKit's `Song.genreNames` actually returns. Apple
//  uses some single-token combined strings ("Jungle/Drum'n'bass",
//  "Death Metal/Black Metal", "IDM/Experimental", "Prog-Rock/Art
//  Rock"); those are kept intact rather than split because that's
//  what we'll see on a real track. Common third-party tags that
//  don't appear in Apple's table (e.g. "synth-pop", "post-punk",
//  "trip-hop") are also included where they serve as transitive
//  bridges between Apple-canonical tags — they sit dormant on a
//  pure-Apple library but help bridge tags carried over from
//  iTunes Match / Bandcamp imports.
//
//  Lineage sources cross-referenced: Apple's published genre-code
//  table (itunespartner.apple.com support 5318, AquaChocomint's
//  AppleStore-Genre-ID mirror), Wikipedia genre-article infoboxes
//  (House, Techno, Dubstep, Drum and bass, Dub, Reggae, Dancehall,
//  Reggaeton, Punk rock, Heavy metal, Soul, Funk, Disco, Hip-hop,
//  Jazz fusion, Bluegrass, Americana, Dance-pop), and AllMusic
//  family trees. Contested edges are noted inline.
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
	/// MusicKit habitually returns a literal "Music" companion
	/// alongside the real genre (e.g. ["Alternative", "Music"]).
	/// "Music" sits in every song's list, so a pairwise "Music"
	/// match would inject ~+0.5 of phantom similarity into every
	/// comparison — we strip it before scoring.
	///
	/// Two empty inputs (after stripping) return 0.5 — neutral,
	/// mirroring how the walk treats missing release dates, so a
	/// song with no real genre tags doesn't get punished. One empty
	/// side returns 0: we have signal on one side and zero overlap
	/// on the other.
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

	// MARK: - Normalization

	private static func normalize(_ s: String) -> String {
		s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Companion strings MusicKit attaches that carry no lineage
	/// signal. "Music" is the big one — present on roughly every
	/// track. Listed normalized; comparison is exact-match against
	/// normalized inputs.
	private static let phantoms: Set<String> = ["music"]

	private static func stripPhantoms(_ genres: [String]) -> [String] {
		genres.filter { !phantoms.contains(normalize($0)) }
	}

	// MARK: - Lineage chains

	/// Ordered lineage chains. Adjacent entries are bigrams; skip-one
	/// is a trigram window; skip-two is a 4-gram window. Chains
	/// overlap on shared ancestors — that's how lineage diverges
	/// from a single 1D ordering. Add new lineage by extending an
	/// existing chain or adding a new one; window distance is
	/// recomputed at static-init time.
	///
	/// Entries are pre-normalized (lowercase, trimmed) so the
	/// adjacency table can key directly without re-normalizing per
	/// lookup. Apple's slash-combined strings ("hip-hop/rap",
	/// "jungle/drum'n'bass", "death metal/black metal",
	/// "idm/experimental", "prog-rock/art rock", "r&b/soul",
	/// "singer/songwriter") are kept as single tokens because that's
	/// the literal value MusicKit returns.
	private static let chains: [[String]] = [
		// MARK: Electronic / Dance
		// Apple splits House/Techno/Trance under Dance (id 17) and
		// keeps Dubstep/Ambient/IDM/Industrial under Electronic (id
		// 7). Both are top-level genres; chains bridge them via
		// shared descendants.
		//
		// Disco → post-disco → House documented at en.wikipedia.org/
		// wiki/House_music; House → Techno at en.wikipedia.org/wiki/
		// Techno (Chicago house listed as stylistic origin).
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
		// Jungle/DnB and Dubstep both descend from UK breakbeat /
		// garage scene. Wikipedia Dubstep infobox: 2-step garage,
		// dub, jungle, broken beat.
		["breakbeat", "jungle/drum'n'bass", "dubstep"],
		["garage", "jungle/drum'n'bass", "dubstep"],
		["dubstep", "bass"],

		// MARK: Reggae lineage — the surprising-chain spine
		// Ska → Reggae → Dub is documented in every reggae history
		// (Wikipedia Reggae infobox: ska, rocksteady, mento as
		// origins). Apple has no "Rocksteady" tag so that link is
		// elided. Dub → Dubstep and Dub → Jungle/DnB are both in
		// the Dub Wikipedia infobox.
		["ska", "reggae", "roots reggae"],
		["reggae", "dub", "dubstep"],
		["reggae", "dub", "jungle/drum'n'bass"],
		["reggae", "dancehall", "modern dancehall"],
		["reggae", "lovers rock"],
		// Reggaetón surfaces in Apple as "Latin Urban" (English
		// storefront) or "Urbano latino" (Latin storefront). Both
		// strings can appear in genreNames; bridge them.
		["dancehall", "modern dancehall", "latin urban"],
		["latin urban", "urbano latino"],
		// The canonical 5-gram bridging reggae to electronic — the
		// example chain the prompt called out, kept verbatim.
		// Reggae→Dub: direct lineage. Dub→Dubstep: direct lineage
		// (Wikipedia Dubstep infobox). Dubstep→Techno: shared UK
		// electronic ancestry and frequent crossover; the contested
		// step in the chain, but worth keeping for the bridge.
		["reggae", "dub", "dubstep", "techno", "house"],

		// MARK: Rock / Alternative / Indie / Punk / Wave
		// Apple keeps Punk + New Wave + Indie Rock + Indie Pop +
		// Grunge + Goth Rock + College Rock + Pop Punk + EMO all
		// under Alternative. Heavy Metal + Hard Rock + Glam Rock +
		// Hair Metal + Death Metal/Black Metal + Prog-Rock/Art Rock
		// + Blues-Rock + Psychedelic under Rock.
		["rock & roll", "rock", "hard rock"],
		["rock", "psychedelic", "hard rock"],
		["rock", "blues-rock", "hard rock"],
		["alternative", "indie rock", "indie pop"],
		["alternative", "college rock", "indie rock"],
		["alternative", "grunge"],
		["alternative", "goth rock"],
		["punk", "new wave"],
		// "post-punk" and "synth-pop" aren't in Apple's table but
		// show up on iTunes Match imports. Keep as transitive
		// bridges from Apple-canonical Punk → New Wave.
		["punk", "post-punk", "new wave"],
		["new wave", "synth-pop"],
		["indie pop", "pop punk", "emo"],
		// Prog-Rock/Art Rock is one combined Apple token; bridge
		// via rock + psychedelic.
		["psychedelic", "prog-rock/art rock"],

		// MARK: Metal
		// Wikipedia Heavy metal infobox: origins blues rock,
		// psychedelic rock, hard rock. Thrash → Death/Black is the
		// canonical extreme-metal evolution.
		["hard rock", "heavy metal", "metal"],
		["heavy metal", "death metal/black metal"],
		["metal", "hair metal", "glam rock"],

		// MARK: Hip-Hop / R&B / Soul / Funk / Disco
		// Soul → Funk → Disco → House is the Black-American
		// dance-music spine (Wikipedia Soul music + Disco
		// derivatives). Hip-hop emerged from funk + disco sampling
		// + DJ culture (Wikipedia Hip-hop origins).
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
		// Trip-hop isn't in Apple's table; Bristol acts surface as
		// Electronic > Downtempo. Bridge downtempo to hip-hop so
		// dub/downtempo-tagged content connects to rap-tagged.
		["dub", "downtempo", "hip-hop/rap"],

		// MARK: Jazz / Blues / Gospel
		// Wikipedia Jazz fusion: bridges jazz and funk/rock.
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
		// Americana Music Association defines Americana as country,
		// folk, blues, soul, bluegrass, gospel, rock (Wikipedia
		// Americana music). Bluegrass infobox: Appalachian folk +
		// country as origins.
		["folk", "traditional folk", "contemporary folk"],
		["folk", "folk-rock"],
		["country", "traditional country", "bluegrass"],
		["country", "bluegrass", "americana"],
		["country", "americana", "alternative country"],
		["singer/songwriter", "folk-rock", "alternative folk"],
		["country", "honky tonk", "outlaw country"],

		// MARK: Pop bridges
		// Apple has no "Dance Pop" tag; bridge via Disco → Pop
		// (Wikipedia Dance-pop origins: disco, post-disco,
		// synth-pop).
		["pop", "adult contemporary", "soft rock"],
		["pop", "teen pop", "k-pop"],
		["pop", "britpop", "indie pop"],
		["pop", "pop/rock", "rock"],
		["disco", "pop"],
		["pop", "synth-pop"],

		// MARK: Latin
		// Apple stores Latin parent (id 12) with Salsa y Tropical,
		// Pop Latino, Música Mexicana, Latin Jazz, Latin Urban,
		// Urbano latino as common children. Latin Jazz overlaps the
		// Jazz family.
		["latin", "pop latino", "urbano latino"],
		["latin", "salsa y tropical", "música tropical"],
		["latin", "latin jazz"],
		["latin", "música mexicana"],

		// MARK: Classical / Soundtrack
		["classical", "soundtrack", "original score"],
		// Wikipedia Ambient music: minimalist + classical influence.
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
