//
//  PlayRandomPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 01/07/2023.
//

import Foundation
import AppIntents
import MusicKit

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
			let request = MusicLibraryRequest<Playlist>()
			let response = try await request.response()
			guard let playlist = response.items.randomElement() else {
				return .result(dialog: IntentDialog("No playlists found"))
			}
			SystemMusicPlayer.shared.queue = [playlist]
			try await SystemMusicPlayer.shared.prepareToPlay()
			try await SystemMusicPlayer.shared.play()
			
			return .result(dialog: IntentDialog.responseSuccess(playlistName: playlist.name))
    }
}

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
fileprivate extension IntentDialog {
    static func responseSuccess(playlistName: String) -> Self {
        "Playing your playlist “\(playlistName)”"
    }
}

