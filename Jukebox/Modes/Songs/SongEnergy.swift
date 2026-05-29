//
//  SongEnergy.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Continuous per-song energy in [0, 1]. The four `EnergyBand`s become
//  labeled ranges of this axis rather than the unit of classification:
//  the band sets a coarse center, and cached BPM floats the song up or
//  down — *across* band lines, so a clubby 130bpm electronic track reads
//  more energetic than a 70bpm ambient-electronic one even though both
//  are "Electronic".
//
//      energy = (1 - bpmWeight)·bandCenter + bpmWeight·bpmEnergy(bpm)
//
//  No BPM cached → pure band center. No band (no embedding and no usable
//  genre) → nil (unknown energy). The embedding is deliberately *not*
//  projected onto a 1-D energy axis: AudioFeaturePrint bunches the bands
//  at cosine 0.96–0.99 (see EnergyCentroids.swift), so a single linear
//  direction barely separates them — BPM is the reliable continuous
//  signal, the embedding's job is the coarse band via EnergyClassifier.
//

import Foundation

enum SongEnergy {
	/// Share of the final energy contributed by BPM vs the band center.
	/// 0.4 lets tempo move a song most of one band's width — enough to
	/// cross a boundary, not enough to override the band wholesale.
	/// Tunable.
	static let bpmWeight: Double = 0.4

	/// BPM range mapped onto [0, 1]. Below `bpmFloor` reads as minimum
	/// energy, above `bpmCeil` as maximum.
	static let bpmFloor: Double = 60
	static let bpmCeil: Double = 160

	/// Continuous energy for a song, or nil when it can't be placed.
	/// `band` is the coarse assignment from
	/// `EnergyClassifier.band(embedding:genres:…)`; `bpm` is the cached
	/// tempo (`EmbeddingStore.bpms`), nil when not yet detected.
	static func value(band: EnergyBand?, bpm: Double?) -> Double? {
		guard let band else { return nil }
		let center = band.centerValue
		guard let bpm else { return center }
		return (1 - bpmWeight) * center + bpmWeight * bpmEnergy(bpm)
	}

	/// Tempo → [0, 1] energy. Higher BPM reads as higher energy, so we do
	/// *not* octave-fold (folding would flatten the 70-vs-140 distinction
	/// this whole axis exists to capture). We only canonicalise obvious
	/// half/double-time detection artifacts at the extremes before the
	/// linear map — a sustained sub-55 or over-200 reading is almost
	/// always the detector landing an octave off.
	static func bpmEnergy(_ bpm: Double) -> Double {
		var b = bpm
		if b < 55 { b *= 2 }
		if b > 200 { b /= 2 }
		return min(1, max(0, (b - bpmFloor) / (bpmCeil - bpmFloor)))
	}
}

extension EnergyBand {
	/// Center of the band's quarter of the [0, 1] energy axis — the
	/// no-BPM fallback value and the band's anchor in the energy blend.
	var centerValue: Double {
		switch self {
		case .any: 0.5
		case .glacial: 0.125
		case .mellow: 0.375
		case .energetic: 0.625
		case .intense: 0.875
		}
	}

	/// The band a continuous energy value falls into — equal 0.25-wide
	/// bins, the inverse of `centerValue`. Generalises the old
	/// `forCurveValue` so the Design curve, the Songs-tab energy target,
	/// and the overview buckets all label energy the same way. `.any` is
	/// intentionally unreachable; it's a filter state, not a position.
	static func forValue(_ energy: Double) -> EnergyBand {
		switch energy {
		case ..<0.25: .glacial
		case ..<0.5: .mellow
		case ..<0.75: .energetic
		default: .intense
		}
	}
}
