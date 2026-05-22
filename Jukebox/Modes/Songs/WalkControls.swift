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
	var energy: EnergyBand
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

/// Flowstate-style intensity bands. Until the audio-feature classifier
/// from #10 lands, energy is matched against the song's `genreNames`
/// via case-insensitive substring keywords — a coarse signal but
/// honest about what we can compute today.
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

	/// Lifted from flowstate's band palette so the popover's chips
	/// match the reference design the user pointed at.
	var tint: Color {
		switch self {
		case .any: .secondary
		case .glacial: Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
		case .mellow: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
		case .energetic: Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255)
		case .intense: Color(red: 255 / 255, green: 45 / 255, blue: 85 / 255)
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
