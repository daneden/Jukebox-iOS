//
//  WalkControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  User-facing knobs that compose over the Songs walk. Three orthogonal
//  axes — meander, energy, decade span — exposed via the bottom-bar
//  popover. Defaults match the curated app behaviour so "reset" returns
//  control to the algorithm.
//
//  Storage is split across three @AppStorage primitives (one per axis)
//  rather than a JSON blob so the keys are debuggable and the defaults
//  decode cleanly when a new field is added later.
//

import SwiftUI

struct WalkControls: Equatable {
	/// Steady (-1.0) ↔ neutral (0) ↔ meandering (+1.0). Negative values
	/// pull the walk toward the first song (seed gravity); positive
	/// values add softmax temperature so the per-step pick is exploratory
	/// rather than greedy. Zero reproduces the current default.
	var meander: Double
	var energy: EnergyBand
	var decadeSpan: DecadeSpan

	static let `default` = WalkControls(
		meander: 0,
		energy: .any,
		decadeSpan: .balanced
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

/// How far the walk is willing to bridge era gaps. Maps to the
/// halflife (in years) of the exponential decay in
/// `SongDeckWalk.eraProximity`. Lower halflife → tighter same-era
/// pairings.
enum DecadeSpan: Int, CaseIterable, Identifiable {
	case tight = 0
	case balanced = 1
	case broad = 2
	case anytime = 3

	var id: Int {
		rawValue
	}

	var displayName: String {
		switch self {
		case .tight: "Same era"
		case .balanced: "Balanced"
		case .broad: "Wide"
		case .anytime: "Any era"
		}
	}

	/// Era-proximity halflife in years. `anytime` uses a huge value so
	/// the decay is effectively flat (every pair scores ~1.0 on era).
	var eraHalflifeYears: Double {
		switch self {
		case .tight: 8
		case .balanced: 20
		case .broad: 40
		case .anytime: 1_000_000
		}
	}
}
