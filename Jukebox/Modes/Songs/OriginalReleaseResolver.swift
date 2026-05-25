//
//  OriginalReleaseResolver.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Resolves the "original" release date for a library song by walking
//  the MusicKit catalog graph and taking the earliest `releaseDate`
//  across the song's albums and each of those albums' `otherVersions`.
//  Covers two failure modes of `Song.releaseDate` for the decade filter:
//
//   - Remasters — a 2022 reissue's `releaseDate` is 2022, but its
//     album's `otherVersions` typically links back to the 1973 original.
//   - Compilations — a 2000 "Greatest Hits" track shares its catalog
//     song with the original 1939 single, so the original album appears
//     in `Song.albums` alongside the compilation.
//
//  Library → catalog bridge mirrors `AudioEmbeddingService.previewURL`:
//  ISRC exact match first, then a free-text catalog search with an
//  artist-substring sanity check. Both gated on the MusicKit dev token
//  being issuable; failures fall through silently and the resolver
//  bails to nil so the next warm pass can retry.

import Foundation
import MusicKit

enum OriginalReleaseResolver {
	/// One-shot entrypoint: checks the cache first, resolves + stores on
	/// miss. Suitable for ad-hoc callers that haven't already prefiltered
	/// against `resolvedIDs`. Throws only when the caller needs to
	/// surface failure (the warmers swallow).
	static func ensureCached(song: Song) async throws {
		let resolved = await OriginalReleaseStore.shared.resolvedIDs(for: [song.id])
		if resolved.contains(song.id.rawValue) { return }
		try await resolveAndStore(song: song)
	}

	/// Pre-filtered entrypoint for the warmer loops: they bulk-fetch
	/// `resolvedIDs` once and iterate the unresolved set, so the
	/// per-song actor hop inside `ensureCached` would be wasted work.
	static func resolveAndStore(song: Song) async throws {
		let date = try await resolve(song: song)
		await OriginalReleaseStore.shared.store(date, for: song.id)
	}

	/// Walks the catalog graph. Returns the earliest `releaseDate`
	/// across:
	///   - the matched catalog song's own `releaseDate`
	///   - each album the song appears on (hydrated via `.with([.albums])`)
	///   - each of those albums' `otherVersions` (hydrated per album)
	///
	/// Returns `nil` (a *resolved* "nothing earlier than library's own
	/// date" outcome) when the union's min isn't earlier than
	/// `song.releaseDate`, or when no catalog match could be made.
	private static func resolve(song: Song) async throws -> Date? {
		guard let catalogSong = try await catalogMatch(for: song) else {
			return nil
		}

		var candidates: [Date] = []
		if let d = catalogSong.releaseDate { candidates.append(d) }

		// Hydrate the song's `.albums` relationship — for a compilation
		// track this typically includes the original release album
		// alongside the compilation.
		let hydratedSong = (try? await catalogSong.with([.albums])) ?? catalogSong
		let albums = hydratedSong.albums ?? []
		for album in albums {
			if let d = album.releaseDate { candidates.append(d) }
			// Per-album `otherVersions` hydration — for a remaster this
			// typically includes the original edition with its earlier
			// `releaseDate`. Hydration failure is non-fatal; we just
			// don't get those candidates.
			let hydratedAlbum = (try? await album.with([.otherVersions])) ?? album
			if let others = hydratedAlbum.otherVersions {
				for other in others {
					if let d = other.releaseDate { candidates.append(d) }
				}
			}
		}

		guard let min = candidates.min() else { return nil }

		// If the union's min isn't earlier than what the library
		// already has, there's nothing to override. Store nil so the
		// warmer marks this song resolved and skips it next pass.
		if let own = song.releaseDate, min >= own { return nil }

		return min
	}

	/// Library song → catalog song. ISRC exact-match first, free-text
	/// search fallback with artist-substring filter. Mirrors the cascade
	/// in `AudioEmbeddingService.previewURL`.
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
