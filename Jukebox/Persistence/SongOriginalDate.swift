//
//  SongOriginalDate.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//
//  Cached "original release date" per library song — the earliest
//  `releaseDate` across the song's catalog albums and each of those
//  albums' `otherVersions`. Lets the decade filter and walk see a
//  remaster's 1973 original instead of its 2022 reissue date, and a
//  compilation track's 1939 single date instead of the 2000 best-of
//  release.
//
//  MusicKit exposes no first-issued / copyright date directly, so this
//  value is computed by `OriginalReleaseResolver` and cached here.
//  `originalDate == nil` means "we looked but didn't find anything
//  earlier than the library's own date" — the row's existence is the
//  "checked" flag; absence means we haven't looked yet.
//
//  `modelVersion` lets us invalidate the cache cleanly if we change
//  the resolver's strategy (e.g. start consulting another catalog
//  relationship). Bump the constant in `OriginalReleaseStore` and old
//  rows are treated as misses on read.

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
