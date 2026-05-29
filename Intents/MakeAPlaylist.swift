//
//  MakeAPlaylist.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//

import AppIntents
import Foundation
import MusicKit

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
struct MakeAPlaylist: AppIntent, PredictableIntent {
	static var title: LocalizedStringResource = "Make a Playlist"
	static var description = IntentDescription(
		"Builds a hidden-gems playlist from your Music library and starts playing it."
	)

	static var parameterSummary: some ParameterSummary {
		Summary("Make a Playlist")
	}

	static var predictionConfiguration: some IntentPredictionConfiguration {
		IntentPrediction {
			DisplayRepresentation(
				title: "Make a Playlist",
				subtitle: "Play 20 hidden gems from your Music library"
			)
		}
	}

	func perform() async throws -> some IntentResult & ProvidesDialog {
		let result = try await GemDeckBuilder.build()
		let deck = result.deck
		guard !deck.isEmpty else {
			return .result(dialog: IntentDialog("Couldn't find any gems to play"))
		}

		// Match SongsView: land within ±spread of the top gem so consecutive
		// runs differ without straying from the seed's neighborhood.
		let spread = min(6, max(0, deck.count - 1))
		let offset = spread == 0 ? 0 : Int.random(in: -spread ... spread)
		let startIdx = ((offset % deck.count) + deck.count) % deck.count
		let seed = deck[startIdx]

		let runwayLength = min(20, deck.count)
		let runway = (0 ..< runwayLength).map { i in
			deck[(startIdx + i) % deck.count]
		}

		guard await MusicPlayback.play(songs: runway) else {
			return .result(dialog: IntentDialog("Unable to play"))
		}

		let name = PlaylistNamer.suggestedName(seedArtist: seed.artistName)
		let seedSnapshot = SongSnapshot(song: seed)
		let runwaySnapshots = runway.map(SongSnapshot.init(song:))
		await HistoryStore.shared.record(
			name: name,
			seed: seedSnapshot,
			runway: runwaySnapshots
		)

		return .result(dialog: IntentDialog("Playing “\(name)”"))
	}
}
