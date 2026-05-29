//
//  OriginalReleaseResolver.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Resolves the "original" release date for a library song by taking the
//  earliest `releaseDate` across its catalog albums and their
//  `otherVersions`. Fixes two `Song.releaseDate` failure modes for the
//  decade filter:
//
//   - Remasters — a 2022 reissue's `releaseDate` is 2022; the album's
//     `otherVersions` links back to the 1973 original.
//   - Compilations — a "Greatest Hits" track shares its catalog song with
//     the original single, so the original album appears in `Song.albums`.
//
//  Library → catalog bridge mirrors `AudioEmbeddingService.previewURL`:
//  ISRC exact match, then free-text search with an artist-substring check.
//  Failures bail to nil so the next warm pass can retry.

import Foundation
import MusicKit

enum OriginalReleaseResolver {
	/// One-shot entrypoint for ad-hoc callers: checks the cache, resolves +
	/// stores on miss.
	static func ensureCached(song: Song) async throws {
		let resolved = await OriginalReleaseStore.shared.resolvedIDs(for: [song.id])
		if resolved.contains(song.id.rawValue) { return }
		try await resolveAndStore(song: song)
	}

	/// Pre-filtered entrypoint for the warmer loops, which bulk-fetch
	/// `resolvedIDs` once and skip `ensureCached`'s redundant per-song hop.
	static func resolveAndStore(song: Song) async throws {
		let date = try await resolve(song: song)
		await OriginalReleaseStore.shared.store(date, for: song.id)
	}

	/// Earliest `releaseDate` across the matched catalog song, its albums,
	/// and those albums' `otherVersions`. Returns `nil` when nothing is
	/// earlier than `song.releaseDate` or no catalog match was made.
	private static func resolve(song: Song) async throws -> Date? {
		guard let catalogSong = try await catalogMatch(for: song) else {
			return nil
		}

		var candidates: [Date] = []
		if let d = catalogSong.releaseDate { candidates.append(d) }

		// `.albums` for a compilation track includes the original album.
		let hydratedSong = (try? await catalogSong.with([.albums])) ?? catalogSong
		let albums = hydratedSong.albums ?? []
		for album in albums {
			if let d = album.releaseDate { candidates.append(d) }
			// `otherVersions` for a remaster includes the earlier original.
			let hydratedAlbum = (try? await album.with([.otherVersions])) ?? album
			if let others = hydratedAlbum.otherVersions {
				for other in others {
					if let d = other.releaseDate { candidates.append(d) }
				}
			}
		}

		guard let min = candidates.min() else { return nil }

		// Nothing earlier than the library's own date — store nil so the
		// warmer marks this resolved and skips it next pass.
		if let own = song.releaseDate, min >= own { return nil }

		return min
	}

	/// Library song → catalog song: ISRC exact-match, then free-text search
	/// with an artist-substring filter. Mirrors `AudioEmbeddingService.previewURL`.
	private static func catalogMatch(for song: Song) async throws -> Song? {
		if let isrc = song.isrc, !isrc.isEmpty {
			let req = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
			if let match = try? await req.response().items.first {
				return match
			}
		}

		let term = "\(song.title) \(song.artistName)"
		let searchReq = MusicCatalogSearchRequest(term: term, types: [Song.self])
		guard let response = try? await searchReq.response() else { return nil }
		let needle = song.artistName.lowercased()
		for candidate in response.songs.prefix(5) {
			let candidateArtist = candidate.artistName.lowercased()
			let artistMatches = candidateArtist.contains(needle) || needle.contains(candidateArtist)
			if artistMatches { return candidate }
		}
		return nil
	}
}
