//
//  SongOriginalDate.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Cached "original release date" per library song — the earliest `releaseDate`
//  across the song's catalog albums and their `otherVersions`. Lets the decade
//  filter and walk see a remaster's 1973 original instead of its 2022 reissue.
//
//  MusicKit exposes no first-issued date directly. `originalDate == nil` means
//  nothing earlier than the library's own date was found — the row's existence
//  is the "checked" flag; absence means not yet looked up.
//
//  `modelVersion` invalidates the cache if the resolver's strategy changes;
//  bump the constant in `OriginalReleaseStore` and old rows are treated as
//  misses.

import Foundation
import SwiftData

@Model
final class SongOriginalDate {
	@Attribute(.unique) var songID: String
	var originalDate: Date?
	var modelVersion: Int
	var resolvedAt: Date

	init(
		songID: String,
		originalDate: Date?,
		modelVersion: Int,
		resolvedAt: Date
	) {
		self.songID = songID
		self.originalDate = originalDate
		self.modelVersion = modelVersion
		self.resolvedAt = resolvedAt
	}
}
