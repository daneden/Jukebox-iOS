//
//  CurvePreset.swift
//  Jukebox
//
//  Named energy-curve presets for the Design App Intent. A full five-point
//  curve is impractical to express by voice, so Shortcuts/Siri pick a preset
//  and Design mode's builder fills it. (Named CurvePreset to avoid the
//  existing CurveShape: Shape in EnergyCurveEditor.)
//

import AppIntents

enum CurvePreset: String, AppEnum {
	case buildUp
	case windDown
	case steady
	case peak
	case valley
	case wave
	case random

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		"Shape"
	}

	static var caseDisplayRepresentations: [CurvePreset: DisplayRepresentation] {
		[
			.buildUp: "Build Up",
			.windDown: "Wind Down",
			.steady: "Steady",
			.peak: "Peak",
			.valley: "Valley",
			.wave: "Wave",
			.random: "Random",
		]
	}

	/// The five-point `EnergyCurve` this preset maps to. `.random` is fresh
	/// per access, so it's evaluated at `perform` time.
	var curve: EnergyCurve {
		switch self {
		case .buildUp: EnergyCurve(points: [0.1, 0.3, 0.5, 0.7, 0.9])
		case .windDown: EnergyCurve(points: [0.9, 0.7, 0.5, 0.3, 0.1])
		case .steady: EnergyCurve(points: [0.5, 0.5, 0.5, 0.5, 0.5])
		case .peak: EnergyCurve(points: [0.2, 0.5, 0.9, 0.5, 0.2])
		case .valley: EnergyCurve(points: [0.8, 0.5, 0.2, 0.5, 0.8])
		case .wave: EnergyCurve(points: [0.3, 0.7, 0.3, 0.7, 0.3])
		case .random: EnergyCurve.random()
		}
	}
}
