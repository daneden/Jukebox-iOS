//
//  CyclingLoadingText.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Rotates through a pool of evocative music-discovery phrases while
//  Playback is searching/building. Sweetens the wait without changing
//  what it actually means — every phrase signals "we're rummaging
//  through your library."

import SwiftUI

struct CyclingLoadingText: View {
	let phrases: [String]
	let interval: TimeInterval

	@State private var index: Int

	init(phrases: [String] = Self.defaultPhrases, interval: TimeInterval = 2.5) {
		self.phrases = phrases
		self.interval = interval
		// Randomise the starting index so two consecutive loads (e.g.
		// pull-to-refresh) don't show the same opening phrase.
		_index = State(initialValue: Int.random(in: 0 ..< max(phrases.count, 1)))
	}

	var body: some View {
		Text(phrases.isEmpty ? "" : phrases[index])
			.contentTransition(.numericText())
			.animation(.smooth(duration: 0.45), value: index)
			.task {
				guard phrases.count > 1 else { return }
				while !Task.isCancelled {
					try? await Task.sleep(for: .seconds(interval))
					if Task.isCancelled { return }
					index = (index + 1) % phrases.count
				}
			}
	}

	/// Music-discovery flavored — these read for both Playlists (sleeve
	/// flipping, etc.) and Songs (digging, B-sides). If a future surface
	/// needs context-specific copy, pass a custom array.
	static let defaultPhrases: [String] = [
		"Crate-digging",
		"Dusting off deep cuts",
		"Sleeve-flipping",
		"Riffling through the racks",
		"Cueing the needle",
		"Warming up the turntable",
		"Threading the reel",
		"Sorting the B-sides",
		"Combing the back catalogue",
		"Polishing the vinyl",
		"Reading the liner notes",
		"Lifting the tone arm",
	]
}

#Preview {
	CyclingLoadingText()
		.font(.subheadline)
		.foregroundStyle(.secondary)
}
