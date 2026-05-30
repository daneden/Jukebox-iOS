//
//  EnergyBandAppEnum.swift
//  Jukebox
//
//  Surfaces the Songs-mode energy bands as a Shortcuts/Siri parameter.
//

import AppIntents

extension EnergyBand: AppEnum {
	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		"Energy"
	}

	static var caseDisplayRepresentations: [EnergyBand: DisplayRepresentation] {
		[
			.any: "Any",
			.glacial: "Glacial",
			.mellow: "Mellow",
			.energetic: "Energetic",
			.intense: "Intense",
		]
	}

	/// Energy filter centred on this band's quarter of the axis; `.any`
	/// clears the filter. Window is half the band width, so `target ± window`
	/// spans exactly the band. Reuses `centerValue` (SongEnergy).
	var energyFilter: EnergyFilter {
		guard self != .any else { return .any }
		return EnergyFilter(target: centerValue, window: 0.125)
	}
}
