//
//  WalkControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Walk knobs — meander, energy, decade range. Stored as primitive
//  @AppStorage keys (one per axis) rather than a JSON blob so keys stay
//  debuggable and defaults decode cleanly when a field is added later.
//

import SwiftUI

struct WalkControls: Equatable {
	/// Steady (-1.0) ↔ neutral (0) ↔ meandering (+1.0). Negative adds seed
	/// gravity; positive adds softmax temperature so picks are exploratory.
	var meander: Double
	var energy: EnergyFilter
	/// Inclusive hard filter on the candidate pool.
	var decadeRange: DecadeRange

	static let `default` = WalkControls(
		meander: 0,
		energy: .any,
		decadeRange: .fullRange
	)

	/// Cohesion weight `g` in [0, 1] in the per-step blend
	/// `(1 - g)·sim(prev) + g·sim(seed)`. Non-zero only toward "steady".
	var seedGravity: Double {
		meander >= 0 ? 0 : min(0.5, -meander * 0.5)
	}

	/// Softmax temperature for the per-step pick. Capped low — much above
	/// 0.15 feels random rather than meandering.
	var stepTemperature: Double {
		meander <= 0 ? 0 : min(0.15, meander * 0.15)
	}
}

/// Continuous energy filter. `target` is a position on the `[0, 1]` energy
/// axis; `window` is the half-width kept around it. `target == nil` means
/// no filter.
struct EnergyFilter: Equatable {
	var target: Double?
	var window: Double

	/// Half-width when first enabled — about one band's spread per side.
	static let defaultWindow: Double = 0.15

	static let minWindow: Double = 0.05
	static let maxWindow: Double = 0.35

	static let any = EnergyFilter(target: nil, window: defaultWindow)

	var isActive: Bool {
		target != nil
	}

	/// True when `energy` is within target ± window, or when inactive.
	func contains(_ energy: Double) -> Bool {
		guard let target else { return true }
		return abs(energy - target) <= window
	}
}

/// Intensity bands — the labeling layer over the continuous `SongEnergy`
/// axis (each band is a 0.25-wide range; see `EnergyBand.forValue`).
enum EnergyBand: Int, CaseIterable, Identifiable, Codable {
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

	/// System colors so tints harmonise across light/dark.
	var tint: Color {
		switch self {
		case .any: .secondary
		case .glacial: .teal
		case .mellow: .blue
		case .energetic: .purple
		case .intense: .red
		}
	}

	/// Label width doubles as an intensity cue — expanded reads calm,
	/// compressed reads urgent.
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
	/// `genreNames`, so keywords must track MusicKit's literal strings —
	/// including Apple's combined slash tokens (see GenreSimilarity).
	var genreKeywords: [String]? {
		switch self {
		case .any: nil
		case .glacial: ["ambient", "classical", "chamber", "acoustic", "folk", "singer/songwriter", "new age", "meditation"]
		case .mellow: ["pop", "soul", "r&b", "jazz", "soft rock", "easy listening", "adult alternative", "bossa"]
		case .energetic: ["rock", "alternative", "dance", "electronic", "house", "funk", "disco", "hip-hop", "rap"]
		case .intense: ["metal", "hardcore", "punk", "industrial", "techno", "drum'n'bass", "jungle", "dubstep"]
		}
	}

	var textView: Text {
		Text(self == .any ? displayName : displayName.uppercased())
			.fontWidth(fontWidth)
			.fontDesign(.default)
			.foregroundStyle(tint)
	}
}

/// Inclusive decade range (e.g. 1970...2000 = 1970s, 1980s, 1990s, 2000s).
/// Both endpoints are decade starts — 1970 means "1970s," not "1970."
struct DecadeRange: Equatable {
	var lower: Int
	var upper: Int

	/// Slider bounds. Songs rarely predate 1900; 2030 covers the current
	/// decade with headroom.
	static let minDecade = 1900
	static let maxDecade = 2030
	static let step = 10

	static let fullRange = DecadeRange(lower: minDecade, upper: maxDecade)

	/// True when the range covers everything — no filtering needed.
	var isUnbounded: Bool {
		lower <= Self.minDecade && upper >= Self.maxDecade
	}

	/// Inclusive containment test.
	func contains(_ decade: Int) -> Bool {
		decade >= lower && decade <= upper
	}
}
