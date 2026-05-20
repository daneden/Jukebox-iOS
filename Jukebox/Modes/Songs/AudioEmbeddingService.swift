//
//  AudioEmbeddingService.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Spike: feed a song's 30-second `previewAssets` clip into Apple's
//  built-in `AudioFeaturePrint` extractor and return a single mean-pooled
//  embedding vector. Cosine distance between two such vectors is our
//  on-device proxy for "do these songs sound similar." All work is local;
//  there's nothing to bundle and no third-party API.
//
//  Apple's `AudioFeaturePrint` outputs a 512-d vector per ~960ms window;
//  for a 30s preview that's ~30 windows, and we mean-pool them so the
//  whole clip collapses to one fixed-size vector. Mean-pooling discards
//  intra-song temporal structure (verse vs chorus) which is fine — we
//  want a per-song fingerprint, not a per-section one.

import AVFoundation
import CoreML
import CreateMLComponents
import Foundation
import MusicKit

enum AudioEmbeddingService {
	enum EmbedError: Error, LocalizedError {
		case noCatalogMatch
		case noPreview
		case downloadFailed(any Error)
		case emptyOutput

		var errorDescription: String? {
			switch self {
			case .noCatalogMatch: "Couldn't find a catalog match for this song (tried ISRC and title/artist search)."
			case .noPreview: "Catalog song has no preview asset."
			case let .downloadFailed(e): "Preview download failed: \(e.localizedDescription)"
			case .emptyOutput: "Feature extractor produced no windows."
			}
		}
	}

	/// Resolve a `MusicKit.Song` to its embedding, hitting the persistent
	/// cache first and falling through to the full compute pipeline (catalog
	/// preview lookup → download → AudioFeaturePrint → mean-pool) on miss.
	/// Computed embeddings are written back to the cache automatically.
	///
	/// Library-fetched songs almost never have `previewAssets` populated —
	/// that field lives on Apple Music catalog metadata, not the library
	/// record, and isn't in `Song.PartialMusicProperty` so we can't lazy-
	/// hydrate it via `.with(...)`. The `previewURL(for:)` helper handles
	/// a cascade of bridges, ordered most-accurate to most-permissive.
	static func embed(song: Song) async throws -> [Float] {
		if let cached = await EmbeddingStore.shared.embedding(for: song.id) {
			return cached
		}
		let url = try await previewURL(for: song)
		let computed = try await embed(previewURL: url)
		await EmbeddingStore.shared.store(computed, for: song.id)
		return computed
	}

	private static func previewURL(for song: Song) async throws -> URL {
		// 1. Already populated (rare for library songs, common for catalog).
		if let url = song.previewAssets?.first?.url {
			return url
		}

		// 2. ISRC bridge — exact catalog match when ISRC is populated.
		//    Requires the MusicKit capability enabled on the dev portal so
		//    the framework can request a developer token. Falls through
		//    silently if either ISRC is nil or the dev token can't be issued.
		if let isrc = song.isrc, !isrc.isEmpty {
			let req = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
			if let match = try? await req.response().items.first,
			   let url = match.previewAssets?.first?.url
			{
				return url
			}
		}

		// 3. Free-text catalog search. Same dev-token requirement; same
		//    silent fallthrough.
		let term = "\(song.title) \(song.artistName)"
		let searchReq = MusicCatalogSearchRequest(term: term, types: [Song.self])
		if let response = try? await searchReq.response() {
			let needle = song.artistName.lowercased()
			for candidate in response.songs.prefix(5) {
				let candidateArtist = candidate.artistName.lowercased()
				let artistMatches = candidateArtist.contains(needle) || needle.contains(candidateArtist)
				guard artistMatches else { continue }
				if let url = candidate.previewAssets?.first?.url {
					return url
				}
			}
		}

		// 4. iTunes Search API — public, no auth, no developer token. The
		//    underlying catalog is the same one Apple Music uses, just
		//    exposed via the older unauthenticated endpoint. Lets the spike
		//    work without the MusicKit capability being configured.
		if let url = try await itunesSearchPreviewURL(title: song.title, artist: song.artistName) {
			return url
		}

		throw EmbedError.noCatalogMatch
	}

	private static func itunesSearchPreviewURL(title: String, artist: String) async throws -> URL? {
		var components = URLComponents(string: "https://itunes.apple.com/search")!
		components.queryItems = [
			URLQueryItem(name: "term", value: "\(title) \(artist)"),
			URLQueryItem(name: "media", value: "music"),
			URLQueryItem(name: "entity", value: "song"),
			URLQueryItem(name: "limit", value: "5"),
		]
		guard let url = components.url else { return nil }

		let (data, _) = try await URLSession.shared.data(from: url)
		let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)

		let needle = artist.lowercased()
		for result in response.results {
			guard let candidateArtist = result.artistName?.lowercased() else { continue }
			let artistMatches = candidateArtist.contains(needle) || needle.contains(candidateArtist)
			guard artistMatches, let previewURL = result.previewUrl else { continue }
			return previewURL
		}
		return nil
	}

	private struct ITunesSearchResponse: Decodable {
		let results: [Result]
		struct Result: Decodable {
			let trackName: String?
			let artistName: String?
			let previewUrl: URL?
		}
	}

	/// Download → decode → AudioFeaturePrint → mean-pool. Returns a 512-d
	/// (the documented `SOUND_VERSION_1` output dim) Float vector.
	static func embed(previewURL: URL) async throws -> [Float] {
		let localURL: URL
		do {
			let (tempURL, _) = try await URLSession.shared.download(from: previewURL)
			localURL = tempURL
		} catch {
			throw EmbedError.downloadFailed(error)
		}
		defer { try? FileManager.default.removeItem(at: localURL) }

		// AudioFeaturePrint windows internally at 0.96s / 50% overlap; we set
		// it explicitly so the choice is visible. ~60 windows per 30s preview,
		// mean-pooled to a single 512-d fingerprint.
		let buffers = try AudioReader.read(contentsOf: localURL)
		let featurePrint = AudioFeaturePrint(windowDuration: 0.96, overlapFactor: 0.5)
		let features = try featurePrint.applied(to: buffers)

		var sum: [Float] = []
		var count = 0
		for try await window in features {
			let scalars = window.feature.scalars
			if sum.isEmpty {
				sum = Array(repeating: 0, count: scalars.count)
			}
			for i in 0 ..< sum.count {
				sum[i] += scalars[i]
			}
			count += 1
		}

		guard count > 0, !sum.isEmpty else { throw EmbedError.emptyOutput }
		let inv = 1.0 / Float(count)
		return sum.map { $0 * inv }
	}

	/// Cosine similarity in [-1, 1]; 1.0 = identical direction in embedding
	/// space ≈ maximally similar. Returns 0 if either vector is zero-length.
	static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
		precondition(a.count == b.count, "embedding dimensions differ")
		var dot: Float = 0
		var na: Float = 0
		var nb: Float = 0
		for i in 0 ..< a.count {
			dot += a[i] * b[i]
			na += a[i] * a[i]
			nb += b[i] * b[i]
		}
		let denom = (na * nb).squareRoot()
		return denom > 0 ? dot / denom : 0
	}
}
