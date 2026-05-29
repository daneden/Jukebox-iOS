//
//  AudioEmbeddingService.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Feeds a song's 30s preview clip into Apple's `AudioFeaturePrint` and
//  mean-pools the per-window vectors into one per-song fingerprint;
//  cosine distance between fingerprints is the on-device similarity proxy.
//  Mean-pooling discards intra-song structure (verse vs chorus) on purpose.

import AVFoundation
import CoreML
import CreateMLComponents
import Foundation
import MusicKit

enum AudioEmbeddingService {
	/// Separate from `URLSession.shared` (which `AsyncImage` uses for
	/// album art) so the warmer's preview downloads don't tie up the
	/// artwork loader's connection pool. Per-host limit + `.background`
	/// service type so these requests yield to user-initiated traffic.
	private static let session: URLSession = {
		let config = URLSessionConfiguration.default
		config.httpMaximumConnectionsPerHost = 2
		config.networkServiceType = .background
		config.waitsForConnectivity = true
		return URLSession(configuration: config)
	}()

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

	/// Resolve a `MusicKit.Song` to its embedding, cache-first, falling
	/// through to the full pipeline (preview lookup → download →
	/// AudioFeaturePrint → mean-pool) on miss and writing back.
	///
	/// BPM detection defaults to off — it adds ~200ms synchronous CPU +
	/// a second decode per song, which competes badly with foreground
	/// MusicKit/artwork work. Background passes (`ensureCached`) turn it
	/// on; the foreground deck warm leaves it off and backfills overnight.
	///
	/// Library-fetched songs almost never have `previewAssets` populated —
	/// that field is catalog metadata, not on the library record, and
	/// isn't in `Song.PartialMusicProperty` so it can't be lazy-hydrated
	/// via `.with(...)`. `previewURL(for:)` cascades bridges instead.
	static func embed(song: Song, computeBPM: Bool = false) async throws -> [Float] {
		if let cached = await EmbeddingStore.shared.embedding(for: song.id) {
			return cached
		}
		do {
			let url = try await previewURL(for: song)
			let (vector, bpm) = try await embed(previewURL: url, computeBPM: computeBPM)
			await EmbeddingStore.shared.store(
				vector,
				bpm: bpm?.bpm,
				bpmConfidence: bpm?.confidence,
				for: song.id
			)
			return vector
		} catch let error as EmbedError {
			// Negative-cache permanent failures so the warmer doesn't
			// redo them every pass. `downloadFailed` stays uncached —
			// it's network-transient/stale-URL, cheaper to retry than
			// to permanently fail a song that would later succeed.
			switch error {
			case .noCatalogMatch, .noPreview, .emptyOutput:
				await EmbeddingStore.shared.recordFailure(
					songID: song.id,
					reason: error.errorDescription ?? "\(error)"
				)
			case .downloadFailed:
				break
			}
			throw error
		}
	}

	private static func previewURL(for song: Song) async throws -> URL {
		// 1. Already populated (rare for library songs, common for catalog).
		if let url = song.previewAssets?.first?.url {
			return url
		}

		// 2. ISRC bridge — exact catalog match. Needs the MusicKit
		//    capability for a dev token; falls through silently without it.
		if let isrc = song.isrc, !isrc.isEmpty {
			let req = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
			if let match = try? await req.response().items.first,
			   let url = match.previewAssets?.first?.url
			{
				return url
			}
		}

		// 3. Free-text catalog search. Same dev-token requirement.
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

		// 4. iTunes Search API — same catalog, unauthenticated endpoint.
		//    Works without the MusicKit capability configured.
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

		let (data, _) = try await session.data(from: url)
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

	/// Download → decode → AudioFeaturePrint → mean-pool, optionally
	/// plus a BPMDetector pass over the same file. BPM is nil when
	/// `computeBPM` is false or the audio defeats the detector
	/// (ambient, classical, free-time).
	static func embed(
		previewURL: URL,
		computeBPM: Bool = false
	) async throws -> (vector: [Float], bpm: BPMDetector.Detection?) {
		let localURL: URL
		do {
			let (tempURL, _) = try await session.download(from: previewURL)
			localURL = tempURL
		} catch {
			throw EmbedError.downloadFailed(error)
		}
		defer { try? FileManager.default.removeItem(at: localURL) }

		// Window params set explicitly for visibility; ~60 windows per
		// 30s preview, mean-pooled to a single 512-d fingerprint.
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
		let vector = sum.map { $0 * inv }

		// BPM re-reads the file via AVAudioFile (cheaper than
		// restructuring AudioReader's stream into raw PCM); detect
		// returns nil on decode hiccups so it can't fail the embedding.
		let bpm = computeBPM ? BPMDetector.detect(audioFileURL: localURL) : nil

		return (vector, bpm)
	}

	/// Library-warmer entrypoint. Ensures the cache row for `song` has
	/// both an embedding and a BPM, computing only what's missing.
	/// Backfills the BPM the foreground deck warm skips (it runs
	/// `embed(song:)` with `computeBPM: false`).
	static func ensureCached(song: Song) async throws {
		let hasEmbedding = await EmbeddingStore.shared.embedding(for: song.id) != nil
		let hasBPM = await EmbeddingStore.shared.hasBPM(for: song.id)
		if hasEmbedding, hasBPM { return }

		do {
			let url = try await previewURL(for: song)

			if !hasEmbedding {
				let (vector, bpm) = try await embed(previewURL: url, computeBPM: true)
				await EmbeddingStore.shared.store(
					vector,
					bpm: bpm?.bpm,
					bpmConfidence: bpm?.confidence,
					for: song.id
				)
			} else if let bpm = try await detectBPMOnly(previewURL: url) {
				await EmbeddingStore.shared.updateBPM(
					bpm: bpm.bpm,
					bpmConfidence: bpm.confidence,
					for: song.id
				)
			}
		} catch let error as EmbedError {
			switch error {
			case .noCatalogMatch, .noPreview, .emptyOutput:
				await EmbeddingStore.shared.recordFailure(
					songID: song.id,
					reason: error.errorDescription ?? "\(error)"
				)
			case .downloadFailed:
				break
			}
			throw error
		}
	}

	/// Re-run BPM detection for a song at a stale `BPMDetector` version.
	/// Runs BPMDetector only (cached embedding untouched), then stamps
	/// the row to the current version — overwriting on a confident
	/// result, or just marking it re-evaluated on nil so the warmer
	/// stops re-fetching it.
	static func redetectBPM(song: Song) async throws {
		do {
			let url = try await previewURL(for: song)
			let detection = try await detectBPMOnly(previewURL: url)
			await EmbeddingStore.shared.refreshBPM(
				bpm: detection?.bpm,
				bpmConfidence: detection?.confidence,
				for: song.id
			)
		} catch let error as EmbedError {
			switch error {
			case .noCatalogMatch, .noPreview, .emptyOutput:
				await EmbeddingStore.shared.recordFailure(
					songID: song.id,
					reason: error.errorDescription ?? "\(error)"
				)
			case .downloadFailed:
				break
			}
			throw error
		}
	}

	/// Download → BPMDetector, skipping AudioFeaturePrint entirely.
	private static func detectBPMOnly(previewURL: URL) async throws -> BPMDetector.Detection? {
		let localURL: URL
		do {
			let (tempURL, _) = try await session.download(from: previewURL)
			localURL = tempURL
		} catch {
			throw EmbedError.downloadFailed(error)
		}
		defer { try? FileManager.default.removeItem(at: localURL) }
		return BPMDetector.detect(audioFileURL: localURL)
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
