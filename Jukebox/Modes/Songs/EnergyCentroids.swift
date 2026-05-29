//
//  EnergyCentroids.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Bundled per-band centroids derived from hand-picked anchor albums.
//  When EnergyCentroids.json is present, the classifier prefers these
//  baked centroids over the genre-keyword-derived ones; absent, it
//  falls back to the library-anchor path.
//
//  Multi-prototype: each band carries several sub-style centroids, not
//  one mean-pooled centroid. One centroid per band collapsed
//  mellow/energetic/intense on top of each other (inter-centroid cosine
//  0.96–0.99) because AudioFeaturePrint bunches everything with
//  vocals+rhythm into a tight ball. Splitting into (band, subStyle)
//  groups lets each centroid be tight; a song belongs to a band if it
//  clears any sub-style's threshold.
//

import Foundation

/// On-disk shape of the bundled anchor manifest (`EnergyAnchors.json`).
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
/// band. Threshold is the median anchor-to-centroid cosine *within this
/// sub-style*, so it self-calibrates per sub-style, not per band.
struct EnergyCentroidPayload: Codable {
	let band: String
	let subStyle: String
	let centroid: [Float]
	let threshold: Float
	let trackCount: Int
	let albumCount: Int
}

/// On-disk shape of the full centroid bundle.
struct EnergyCentroidBundle: Codable {
	let bands: [String: [EnergyCentroidPayload]]
}

enum EnergyCentroidsLoader {
	/// In-memory cache of the bundled centroids. Nil when the resource
	/// is absent or fails to decode; the classifier falls back either way.
	static let bundled: EnergyCentroidBundle? = {
		guard let url = Bundle.main.url(forResource: "EnergyCentroids", withExtension: "json"),
		      let data = try? Data(contentsOf: url),
		      let decoded = try? JSONDecoder().decode(EnergyCentroidBundle.self, from: data)
		else {
			return nil
		}
		return decoded
	}()

	/// Loads the anchor manifest from the bundle. Used by the centroid
	/// builder; not needed at runtime once centroids are baked.
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
	/// Stable key in the centroid JSON. Decoupled from `displayName` so
	/// UI copy changes don't invalidate committed centroid files.
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
