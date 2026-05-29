//
//  HistoryPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Snapshots the ~20-song runway a Songs-mode Play produced; the deck
//  reshuffles every session, so it can't be reconstructed otherwise.

import Foundation
import SwiftData

/// Run-level user feedback. The Bad Run action bulk-blocks adjacent transitions.
enum HistoryFeedback: String, Codable {
	case none
	case liked
	case disliked
}

@Model
final class HistoryPlaylist {
	@Attribute(.unique) var id: UUID
	var playedAt: Date
	/// Default-initialised for SwiftData lightweight migration; UI falls
	/// back to `seedTitle` when empty.
	var name: String = ""
	/// Default value lets older rows migrate cleanly under SwiftData.
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
	/// Fetching songs by `position` recovers the exact playback order.
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
