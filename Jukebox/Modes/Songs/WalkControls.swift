//
//  WalkControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  User-facing knobs that compose over the Songs walk. Three orthogonal
//  axes — meander, energy, decade range — exposed via the bottom-bar
//  popover. Defaults match the curated app behaviour so "reset" returns
//  control to the algorithm.
//
//  Storage is split across primitive @AppStorage keys (one per axis,
//  two for the decade range endpoints) rather than a JSON blob so
//  the keys are debuggable and the defaults decode cleanly when a
//  new field is added later.
//

import SwiftUI

struct WalkControls: Equatable {
	/// Steady (-1.0) ↔ neutral (0) ↔ meandering (+1.0). Negative values
	/// pull the walk toward the first song (seed gravity); positive
	/// values add softmax temperature so the per-step pick is exploratory
	/// rather than greedy. Zero reproduces the current default.
	var meander: Double
	var energy: EnergyFilter
	/// Inclusive decade range applied as a hard filter on the candidate
	/// pool. Default spans `DecadeRange.fullRange` so "no filter" is
	/// just leaving both thumbs at the extremes.
	var decadeRange: DecadeRange

	static let `default` = WalkControls(
		meander: 0,
		energy: .any,
		decadeRange: .fullRange
	)

	/// Cohesion weight `g` in [0, 1] passed to the per-step score blend
	/// `(1 - g)·sim(prev) + g·sim(seed)`. Non-zero only when the user has
	/// pulled the slider toward "steady".
	var seedGravity: Double {
		meander >= 0 ? 0 : min(0.5, -meander * 0.5)
	}

	/// Softmax temperature `T` for the per-step pick. 0 = greedy
	/// (current behaviour); higher = candidates 2/3/4 win more often.
	/// Capped low — much above 0.15 starts feeling random rather than
	/// meandering.
	var stepTemperature: Double {
		meander <= 0 ? 0 : min(0.15, meander * 0.15)
	}
}

/// Continuous energy filter for the Songs walk. `target` is a position
/// on the `[0, 1]` energy axis (`SongEnergy`); `window` is the half-width
/// kept around it. `target == nil` means no energy filter. The matching
/// `EnergyBand` for labeling/tinting is `EnergyBand.forValue(target)`.
struct EnergyFilter: Equatable {
	var target: Double?
	var window: Double

	/// Default half-width when the filter is first enabled — about one
	/// band's worth of spread on either side.
	static let defaultWindow: Double = 0.15

	/// Sensible bounds for the window control.
	static let minWindow: Double = 0.05
	static let maxWindow: Double = 0.35

	static let any = EnergyFilter(target: nil, window: defaultWindow)

	var isActive: Bool {
		target != nil
	}

	/// True when `energy` falls inside the target ± window. Always true
	/// when the filter is inactive.
	func contains(_ energy: Double) -> Bool {
		guard let target else { return true }
		return abs(energy - target) <= window
	}
}

/// Flowstate-style intensity bands. Now the *labeling* layer over the
/// continuous `SongEnergy` axis (each band is a 0.25-wide range — see
/// `EnergyBand.forValue`/`centerValue`) as well as the unit the
/// `EnergyClassifier` assigns. Tints/labels drive the energy chip and
/// the overview buckets.
enum EnergyBand: Int, CaseIterable, Identifiable {
	case any = 0
	case glacial = 1
	case mellow = 2
	case energetic = 3
	case intense = 4

	var id: Int {
		rawValue
	}

	var displayName: String {
		switch self {
		case .any: "Any"
		case .glacial: "Glacial"
		case .mellow: "Mellow"
		case .energetic: "Energetic"
		case .intense: "Intense"
		}
	}

	/// Tint applied to the energy chip's glass background. System
	/// colors so they harmonise with the rest of the SwiftUI palette
	/// across light/dark.
	var tint: Color {
		switch self {
		case .any: .secondary
		case .glacial: .purple
		case .mellow: .blue
		case .energetic: .pink
		case .intense: .red
		}
	}

	/// Font width used on the energy chip — turns the label into a
	/// visual cue for intensity (expanded reads calmer, compressed
	/// reads tighter/more urgent).
	var fontWidth: Font.Width {
		switch self {
		case .any: .standard
		case .glacial: .expanded
		case .mellow: .standard
		case .energetic: .condensed
		case .intense: .compressed
		}
	}

	/// nil = no filter. Matched as case-insensitive substrings against
	/// each candidate's `genreNames` — so "Indie Rock" hits "rock",
	/// "Jungle/Drum'n'bass" hits "drum'n'bass". Keywords track the
	/// literal strings MusicKit returns (Apple's combined slash tokens
	/// stay intact — see GenreSimilarity for the canonical list).
	var genreKeywords: [String]? {
		switch self {
		case .any: nil
		case .glacial: ["ambient", "classical", "chamber", "acoustic", "folk", "singer/songwriter", "new age", "meditation"]
		case .mellow: ["pop", "soul", "r&b", "jazz", "soft rock", "easy listening", "adult alternative", "bossa"]
		case .energetic: ["rock", "alternative", "dance", "electronic", "house", "funk", "disco", "hip-hop", "rap"]
		case .intense: ["metal", "hardcore", "punk", "industrial", "techno", "drum'n'bass", "jungle", "dubstep"]
		}
	}
}

/// Inclusive decade range (e.g. 1970...2000 = 1970s, 1980s, 1990s, 2000s).
/// Both endpoints are decade starts — 1970 means "1970s," not "1970."
struct DecadeRange: Equatable {
	var lower: Int
	var upper: Int

	/// Library bounds the range slider operates in. Songs predate 1900
	/// extremely rarely; 2030 covers the current decade with a couple
	/// of years of headroom.
	static let minDecade = 1900
	static let maxDecade = 2030
	static let step = 10

	static let fullRange = DecadeRange(lower: minDecade, upper: maxDecade)

	/// True when the range covers everything — no filtering needed.
	var isUnbounded: Bool {
		lower <= Self.minDecade && upper >= Self.maxDecade
	}

	/// Inclusive containment test. Used to filter candidates by their
	/// `releaseDecade`.
	func contains(_ decade: Int) -> Bool {
		decade >= lower && decade <= upper
	}
}
