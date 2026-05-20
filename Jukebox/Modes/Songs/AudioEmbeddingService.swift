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
		case noISRC
		case noCatalogMatch
		case noPreview
		case downloadFailed(any Error)
		case emptyOutput

		var errorDescription: String? {
			switch self {
			case .noISRC: "Song has no ISRC — can't bridge to catalog for a preview."
			case .noCatalogMatch: "No catalog match found for this song's ISRC."
			case .noPreview: "Catalog song has no preview asset."
			case let .downloadFailed(e): "Preview download failed: \(e.localizedDescription)"
			case .emptyOutput: "Feature extractor produced no windows."
			}
		}
	}

	/// Resolve a `MusicKit.Song` to a 30s preview URL, then embed it.
	///
	/// Library-fetched songs almost never have `previewAssets` populated —
	/// that field lives on the Apple Music catalog metadata, not the local
	/// library record, and isn't in `Song.PartialMusicProperty` so we can't
	/// hydrate it via `.with(...)`. We bridge via ISRC: catalog-search by
	/// the library song's ISRC, take the matched catalog song's preview.
	static func embed(song: Song) async throws -> [Float] {
		let url = try await previewURL(for: song)
		return try await embed(previewURL: url)
	}

	private static func previewURL(for song: Song) async throws -> URL {
		if let url = song.previewAssets?.first?.url {
			return url
		}
		guard let isrc = song.isrc, !isrc.isEmpty else {
			throw EmbedError.noISRC
		}
		let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
		let response = try await request.response()
		guard let catalogSong = response.items.first else {
			throw EmbedError.noCatalogMatch
		}
		guard let url = catalogSong.previewAssets?.first?.url else {
			throw EmbedError.noPreview
		}
		return url
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
