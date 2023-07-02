//
//  PlayRandomPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 01/07/2023.
//

import Foundation
import AppIntents

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

    func perform() async throws -> some IntentResult {
			let libraryManager = LibraryManager.shared
			await libraryManager.getPlaylists()
			
			if let playlist = libraryManager.playlists.randomElement() {
				await libraryManager.playPlaylist(playlist: playlist)
				return .result()
			} else {
				throw AppIntentError.restartPerform
			}
    }
}

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
fileprivate extension IntentDialog {
    static var shuffleParameterPrompt: Self {
        "Turn on song shuffle?"
    }
    static func responseSuccess(playlistName: String) -> Self {
        "Ok, playing your playlist “\(playlistName)”"
    }
}

