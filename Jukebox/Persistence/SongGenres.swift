//
//  SongGenres.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Cached genre names per library song. MusicKit returns `genreNames` empty
//  from a `MusicLibraryRequest`; the genres only come from hydrating the
//  `.genres` relationship, a per-song round-trip too expensive to do live, so
//  it's resolved once and cached here.
//
//  An empty `genreNames` array is a resolved "no genre" outcome — the row's
//  existence is the "checked" flag; absence means not yet hydrated.
//
//  `modelVersion` invalidates the cache if the hydration strategy changes;
//  bump the constant in `GenreStore` and old rows are treated as misses.

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
