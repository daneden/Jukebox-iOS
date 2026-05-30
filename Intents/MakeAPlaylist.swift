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
		"Builds a hidden-gems playlist from your Music library and plays it. Leave the filters unset to use the ones from the Songs tab."
	)

	/// Unset → fall back to the energy filter saved in the Songs tab.
	@Parameter(title: "Energy")
	var energy: EnergyBand?

	/// Decade endpoints (e.g. 1980). Unset → fall back to the saved range.
	@Parameter(title: "From decade")
	var fromDecade: Int?

	@Parameter(title: "To decade")
	var toDecade: Int?

	@Parameter(title: "Number of songs", default: 20, inclusiveRange: (1, 50))
	var count: Int

	@Parameter(title: "Start Playing", default: true)
	var startPlaying: Bool

	static var parameterSummary: some ParameterSummary {
		Summary("Make a playlist") {
			\.$energy
			\.$fromDecade
			\.$toDecade
			\.$count
			\.$startPlaying
		}
	}

	static var predictionConfiguration: some IntentPredictionConfiguration {
		IntentPrediction {
			DisplayRepresentation(
				title: "Make a Playlist",
				subtitle: "Play hidden gems from your Music library"
			)
		}
	}

	func perform() async throws -> some IntentResult & ReturnsValue<GeneratedPlaylistEntity> & ProvidesDialog {
		var controls = WalkControls.saved()
		if let energy {
			controls.energy = energy.energyFilter
		}
		if fromDecade != nil || toDecade != nil {
			controls.decadeRange = Self.decadeRange(from: fromDecade, to: toDecade, base: controls.decadeRange)
		}

		guard let entry = try await IntentActions.makeGemsPlaylist(
			controls: controls,
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

	/// Combine the supplied decade endpoints with the saved range, snapping
	/// to decade starts and clamping to `DecadeRange`'s bounds.
	static func decadeRange(from: Int?, to: Int?, base: DecadeRange) -> DecadeRange {
		func snap(_ year: Int) -> Int {
			let decade = (year / 10) * 10
			return min(DecadeRange.maxDecade, max(DecadeRange.minDecade, decade))
		}
		var lower = from.map(snap) ?? base.lower
		var upper = to.map(snap) ?? base.upper
		if lower > upper { swap(&lower, &upper) }
		return DecadeRange(lower: lower, upper: upper)
	}
}
