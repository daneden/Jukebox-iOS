//
//  PlaybackIntentError.swift
//  Jukebox
//
//  Shared, user-facing failure cases for the playback App Intents.
//

import AppIntents
import Foundation

enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
	case noGems
	case noPlaylists
	case playbackFailed
	case nothingToSave
	case songsUnavailable

	var localizedStringResource: LocalizedStringResource {
		switch self {
		case .noGems: "Couldn't find any gems to play."
		case .noPlaylists: "No playlists found in your library."
		case .playbackFailed: "Couldn't start playback."
		case .nothingToSave: "There's no generated playlist to save yet."
		case .songsUnavailable: "None of these songs are in your Music library anymore."
		}
	}
}
