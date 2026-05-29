//
//  SongGenres.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Cached genre names per library song. MusicKit never populates the
//  `genreNames` attribute on songs returned from a `MusicLibraryRequest`
//  — it comes back empty — so the only way to read a library song's
//  genres is to hydrate the `.genres` relationship (`song.with([.genres])`,
//  then `genres?.map(\.name)`). That's a per-song round-trip, far too
//  expensive to do live in the walk's N² loop or over the 10k analysis
//  pool, so `LibraryEmbeddingWarmer` resolves it once and caches the
//  strings here.
//
//  An empty `genreNames` array is a *resolved* "this song genuinely has
//  no genre" outcome — the row's existence is the "checked" flag, absence
//  means we haven't hydrated it yet (mirrors `SongOriginalDate`).
//
//  `modelVersion` invalidates the cache if the hydration strategy changes
//  (e.g. start rolling sub-genres up to their `Genre.parent`). Bump the
//  constant in `GenreStore` and old rows are treated as misses on read.

import Foundation
import SwiftData

@Model
final class SongGenres {
	@Attribute(.unique) var songID: String
	var genreNames: [String]
	var modelVersion: Int
	var resolvedAt: Date

	init(
		songID: String,
		genreNames: [String],
		modelVersion: Int,
		resolvedAt: Date
	) {
		self.songID = songID
		self.genreNames = genreNames
		self.modelVersion = modelVersion
		self.resolvedAt = resolvedAt
	}
}
