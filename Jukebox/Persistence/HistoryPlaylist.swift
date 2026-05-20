//
//  HistoryPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Each tap on Play in Songs mode produces an implicit playlist — a
//  similarity-walked runway of ~20 songs starting from whatever was
//  focused. That runway is worth keeping around: it's the "playlist"
//  the user actually heard, and there's no other way to reconstruct it
//  later because the deck reshuffles every session.

import Foundation
import SwiftData

/// Run-level user feedback. `liked` / `disliked` are mutually exclusive;
/// `none` is the default. Stored on `HistoryPlaylist` and consumed by
/// the UI for the visual indicator and by the Bad Run action which
/// bulk-blocks adjacent transitions.
enum HistoryFeedback: String, Codable {
	case none
	case liked
	case disliked
}

@Model
final class HistoryPlaylist {
	@Attribute(.unique) var id: UUID
	var playedAt: Date
	/// Whimsical name generated at record time. Default-initialised so
	/// rows persisted before the column existed migrate cleanly under
	/// SwiftData's lightweight migration; the UI falls back to
	/// `seedTitle` when `name` is empty.
	var name: String = ""
	/// Persisted as the enum's raw string. Default value lets older rows
	/// migrate cleanly under SwiftData lightweight migration.
	var feedbackRaw: String = HistoryFeedback.none.rawValue
	var seedSongID: String
	var seedTitle: String
	var seedArtist: String

	@Relationship(deleteRule: .cascade, inverse: \HistorySong.playlist)
	var songs: [HistorySong] = []

	var feedback: HistoryFeedback {
		get { HistoryFeedback(rawValue: feedbackRaw) ?? .none }
		set { feedbackRaw = newValue.rawValue }
	}

	init(
		id: UUID = UUID(),
		playedAt: Date,
		name: String,
		seedSongID: String,
		seedTitle: String,
		seedArtist: String
	) {
		self.id = id
		self.playedAt = playedAt
		self.name = name
		self.seedSongID = seedSongID
		self.seedTitle = seedTitle
		self.seedArtist = seedArtist
	}
}

@Model
final class HistorySong {
	var songID: String
	var title: String
	var artistName: String
	var albumTitle: String?
	/// Position within the parent playlist; the runway is ordered, so
	/// fetching songs by `position` recovers the exact playback order.
	var position: Int
	var playlist: HistoryPlaylist?

	init(
		songID: String,
		title: String,
		artistName: String,
		albumTitle: String?,
		position: Int
	) {
		self.songID = songID
		self.title = title
		self.artistName = artistName
		self.albumTitle = albumTitle
		self.position = position
	}
}
