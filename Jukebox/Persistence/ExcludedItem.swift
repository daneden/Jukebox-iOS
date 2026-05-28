//
//  ExcludedItem.swift
//  Jukebox
//
//  Created by Daniel Eden on 28/05/2026.
//
//  An item the user has flagged as ineligible for future decks via the
//  dial's context menu. One model covers every grain the user can
//  remove at — a single song, a whole album, an artist, or a playlist —
//  discriminated by `kind` and matched on `key`.
//
//  Hard exclusion, not a soft downrank: the user explicitly removed it,
//  so the builder drops it outright rather than scoring it low (that's
//  what the recency penalty in `GemScorer` is for). Distinct concept
//  from `BlockedTransition` (which only forbids two songs being
//  *adjacent*), so it lives in its own store and sqlite.

import Foundation
import MusicKit
import SwiftData

enum ExclusionKind: String, Codable {
	case song
	case album
	case artist
	case playlist
}

@Model
final class ExcludedItem {
	/// Canonical match key, namespaced by kind so a song id can't collide
	/// with an artist name. Built by the `key(...)` helpers below so the
	/// store and the filter agree on the exact string.
	@Attribute(.unique) var key: String
	var kindRaw: String
	/// Human-readable label for a future management screen ("Remove" is a
	/// one-way door today). Not used for matching.
	var label: String
	var blockedAt: Date

	var kind: ExclusionKind {
		ExclusionKind(rawValue: kindRaw) ?? .song
	}

	init(key: String, kind: ExclusionKind, label: String) {
		self.key = key
		kindRaw = kind.rawValue
		self.label = label
		blockedAt = Date()
	}

	// MARK: - Key construction

	//
	// Album is keyed on artist + title rather than title alone: a personal
	// library can hold two unrelated "Greatest Hits", and over-blocking
	// both when the user removed one is more surprising than leaving a
	// straggler on a multi-artist compilation. Separator is the ASCII unit
	// separator so it can't occur inside a real artist/title string.

	static func songKey(_ id: String) -> String {
		"song\u{1F}\(id)"
	}

	static func artistKey(_ name: String) -> String {
		"artist\u{1F}\(name)"
	}

	static func albumKey(artist: String, title: String) -> String {
		"album\u{1F}\(artist)\u{1F}\(title)"
	}

	static func playlistKey(_ id: String) -> String {
		"playlist\u{1F}\(id)"
	}
}

/// Immutable snapshot of the current exclusion set, handed out of the
/// actor so the deck builder can filter the candidate pool without
/// hopping back per song. Membership checks are O(1) against the sets.
struct Exclusions {
	let songIDs: Set<String>
	let artistNames: Set<String>
	/// Keys are `ExcludedItem.albumKey(artist:title:)` strings.
	let albumKeys: Set<String>

	func excludes(song: Song) -> Bool {
		if songIDs.contains(song.id.rawValue) { return true }
		if artistNames.contains(song.artistName) { return true }
		if let album = song.albumTitle,
		   albumKeys.contains(ExcludedItem.albumKey(artist: song.artistName, title: album))
		{
			return true
		}
		return false
	}
}
