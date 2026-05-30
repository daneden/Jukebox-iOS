//
//  DesignPlaylist.swift
//  Jukebox
//
//  Designs a playlist along a named energy curve — the Siri/Shortcuts
//  surface for Design mode.
//

import AppIntents
import Foundation
import MusicKit

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
struct DesignPlaylist: AppIntent, PredictableIntent {
	static var title: LocalizedStringResource = "Design a Playlist"
	static var description = IntentDescription(
		"Designs a playlist that rises and falls along an energy curve, then plays it."
	)

	@Parameter(title: "Shape", default: .buildUp)
	var shape: CurvePreset

	@Parameter(title: "Number of songs", default: 20, inclusiveRange: (10, 50))
	var count: Int

	@Parameter(title: "Start Playing", default: true)
	var startPlaying: Bool

	static var parameterSummary: some ParameterSummary {
		Summary("Design a \(\.$shape) playlist of \(\.$count) songs") {
			\.$startPlaying
		}
	}

	static var predictionConfiguration: some IntentPredictionConfiguration {
		IntentPrediction {
			DisplayRepresentation(
				title: "Design a Playlist",
				subtitle: "Build a playlist along an energy curve"
			)
		}
	}

	func perform() async throws -> some IntentResult & ReturnsValue<GeneratedPlaylistEntity> & ProvidesDialog {
		guard let entry = try await IntentActions.designPlaylist(
			curve: shape.curve,
			count: count,
			startPlaying: startPlaying
		) else {
			throw PlaybackIntentError.noGems
		}

		let dialog: IntentDialog = startPlaying
			? "Playing “\(entry.displayName)”"
			: "Made “\(entry.displayName)”"
		return .result(value: GeneratedPlaylistEntity(entry), dialog: dialog)
	}
}
