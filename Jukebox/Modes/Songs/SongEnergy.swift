//
//  SongEnergy.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Continuous per-song energy in [0, 1]: the band sets a coarse center,
//  and cached BPM floats the song up or down across band lines.
//
//      energy = (1 - bpmWeight)·bandCenter + bpmWeight·bpmEnergy(bpm)
//
//  No BPM → pure band center; no band → nil. The embedding is deliberately
//  not projected onto a 1-D energy axis — AudioFeaturePrint bunches the
//  bands at cosine 0.96–0.99, so BPM is the reliable continuous signal and
//  the embedding only supplies the coarse band via EnergyClassifier.
//

import Foundation
import SwiftUI

enum SongEnergy {
	/// Share of energy from BPM vs band center. Modest so the more reliable
	/// band leads and tempo only nudges across boundaries — detected BPM
	/// carries octave-detection noise. Tunable.
	static let bpmWeight: Double = 0.3

	/// BPM range mapped onto [0, 1]; clamped below `bpmFloor` / above `bpmCeil`.
	static let bpmFloor: Double = 60
	static let bpmCeil: Double = 160

	/// Continuous energy for a song, or nil when it can't be placed.
	static func value(band: EnergyBand?, bpm: Double?) -> Double? {
		guard let band else { return nil }
		let center = band.centerValue
		guard let bpm else { return center }
		return (1 - bpmWeight) * center + bpmWeight * bpmEnergy(bpm)
	}

	/// Tempo → [0, 1] energy. Deliberately not octave-folded (unlike the
	/// walk) — folding would flatten the 70-vs-140 distinction this axis
	/// exists for. Only the extremes are canonicalised, where a sub-55 or
	/// over-200 reading is almost always the detector an octave off.
	static func bpmEnergy(_ bpm: Double) -> Double {
		var b = bpm
		if b < 55 { b *= 2 }
		if b > 200 { b /= 2 }
		return min(1, max(0, (b - bpmFloor) / (bpmCeil - bpmFloor)))
	}
}

extension EnergyBand {
	/// Center of the band's quarter of the energy axis — the no-BPM fallback
	/// and the band's anchor in the blend.
	var centerValue: Double {
		switch self {
		case .any: 0.5
		case .glacial: 0.125
		case .mellow: 0.375
		case .energetic: 0.625
		case .intense: 0.875
		}
	}

	/// The band a continuous energy value falls into — equal 0.25-wide bins,
	/// the inverse of `centerValue`. `.any` is intentionally unreachable;
	/// it's a filter state, not a position.
	static func forValue(_ energy: Double) -> EnergyBand {
		switch energy {
		case ..<0.25: .glacial
		case ..<0.5: .mellow
		case ..<0.75: .energetic
		default: .intense
		}
	}

	/// Color for a continuous energy value: band tints blended across their
	/// centres, giving the scatter a smooth gradient up the energy axis.
	static func color(forEnergy energy: Double) -> Color {
		let stops: [(center: Double, color: Color)] = [
			(EnergyBand.glacial.centerValue, EnergyBand.glacial.tint),
			(EnergyBand.mellow.centerValue, EnergyBand.mellow.tint),
			(EnergyBand.energetic.centerValue, EnergyBand.energetic.tint),
			(EnergyBand.intense.centerValue, EnergyBand.intense.tint),
		]
		guard let first = stops.first, energy > first.center else { return stops[0].color }
		for i in 1 ..< stops.count where energy <= stops[i].center {
			let lo = stops[i - 1]
			let hi = stops[i]
			let t = (energy - lo.center) / (hi.center - lo.center)
			return lo.color.mix(with: hi.color, by: t)
		}
		return stops[stops.count - 1].color
	}
}
