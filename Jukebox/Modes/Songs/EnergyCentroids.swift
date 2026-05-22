//
//  EnergyCentroids.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Bundled per-band centroids derived from hand-picked anchor albums
//  (see EnergyAnchors.json, sourced from flowstate.daneden.me and
//  broadened across genres). When EnergyCentroids.json is present in
//  the app bundle, the classifier prefers these baked centroids over
//  the genre-keyword-derived ones — the curation is more reliable
//  than Apple's coarse genre tags.
//
//  **Multi-prototype:** each band carries several sub-style centroids
//  rather than one mean-pooled centroid. A first pass with one
//  centroid per band collapsed mellow/energetic/intense on top of
//  each other in embedding space (inter-centroid cosine 0.96–0.99,
//  above their own self-thresholds), because AudioFeaturePrint bunches
//  everything with vocals+rhythm into a tight ball. Splitting each
//  band into (band, subStyle) groups gives each group's centroid room
//  to be tight, and a song belongs to a band if it clears the
//  threshold of *any* sub-style in that band.
//
//  The centroid file is generated on-device via the debug-only
//  Energy Centroid Builder, then committed to the repo as a bundled
//  resource. Until that commit lands, the file is absent and the
//  classifier falls back to the library-anchor path.
//

import Foundation

/// On-disk shape of the bundled anchor manifest. Mirrors the JSON in
/// `EnergyAnchors.json` — a list of `(band, artist, album)` triples
/// with an opaque `_about` key the decoder ignores.
struct EnergyAnchorManifest: Decodable {
	let anchors: [EnergyAnchor]
}

struct EnergyAnchor: Decodable, Hashable {
	let band: String
	let subStyle: String
	let artist: String
	let album: String
}

/// On-disk shape of a single sub-style centroid + threshold within a
/// band. Centroid dimensionality matches `AudioFeaturePrint`'s output
/// (512 as of `SOUND_VERSION_1`); threshold is the median anchor-to-
/// centroid cosine *within this sub-style* — so a tight sub-style
/// gets a high threshold and a loose one gets a low one. Self-
/// calibrating per sub-style, not per band.
struct EnergyCentroidPayload: Codable {
	let band: String
	let subStyle: String
	let centroid: [Float]
	let threshold: Float
	/// Diagnostic metadata: how many tracks contributed, sourced from
	/// how many distinct anchor albums. Helpful when sanity-checking
	/// a freshly-rebuilt centroid before committing it.
	let trackCount: Int
	let albumCount: Int
}

/// On-disk shape of the full centroid bundle. Each band maps to a
/// list of sub-style payloads — a song belongs to a band if it
/// clears any sub-style's threshold (OR semantics).
struct EnergyCentroidBundle: Codable {
	let bands: [String: [EnergyCentroidPayload]]
}

enum EnergyCentroidsLoader {
	/// In-memory cache of the bundled centroids. Loaded once on first
	/// access; subsequent calls are free. Nil when the bundle resource
	/// is absent (early in the rollout) or fails to decode — the
	/// classifier treats both the same way and falls back.
	static let bundled: EnergyCentroidBundle? = {
		guard let url = Bundle.main.url(forResource: "EnergyCentroids", withExtension: "json"),
		      let data = try? Data(contentsOf: url),
		      let decoded = try? JSONDecoder().decode(EnergyCentroidBundle.self, from: data)
		else {
			return nil
		}
		return decoded
	}()

	/// Loads the anchor manifest from the bundle. The builder uses this;
	/// it's not needed at runtime once the centroids are baked, but
	/// staying loadable lets a debug session re-derive centroids without
	/// any source-code changes.
	static func loadAnchors() -> [EnergyAnchor] {
		guard let url = Bundle.main.url(forResource: "EnergyAnchors", withExtension: "json"),
		      let data = try? Data(contentsOf: url),
		      let decoded = try? JSONDecoder().decode(EnergyAnchorManifest.self, from: data)
		else {
			return []
		}
		return decoded.anchors
	}
}

extension EnergyBand {
	/// Stable string identifier used as the key in the centroid JSON.
	/// Decoupled from `displayName` so we can tweak UI copy without
	/// invalidating committed centroid files.
	var bundleKey: String? {
		switch self {
		case .any: nil
		case .glacial: "glacial"
		case .mellow: "mellow"
		case .energetic: "energetic"
		case .intense: "intense"
		}
	}
}
