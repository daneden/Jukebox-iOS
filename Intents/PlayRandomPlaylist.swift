//
//  PlayRandomPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 01/07/2023.
//

import AppIntents
import Foundation
import MusicKit
import SwiftUI

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
struct PlayRandomPlaylist: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent {
	static let intentClassName = "PlayRandomPlaylistIntent"

	static var title: LocalizedStringResource = "Play Random Playlist"
	static var description = IntentDescription("Plays a random playlist from your Music library")

	static var parameterSummary: some ParameterSummary {
		Summary("Play Random Playlist")
	}

	static var predictionConfiguration: some IntentPredictionConfiguration {
		IntentPrediction {
			DisplayRepresentation(
				title: "Play a Random Playlist",
				subtitle: "Play a random playlist from your Music library"
			)
		}
	}

	func perform() async throws -> some IntentResult & ProvidesDialog {
		let result = await IntentActions.playRandomPlaylist()
		guard let name = result.name else {
			throw PlaybackIntentError.noPlaylists
		}
		guard result.ok else {
			throw PlaybackIntentError.playbackFailed
		}
		return .result(dialog: "Playing your playlist “\(name)”")
	}
}
