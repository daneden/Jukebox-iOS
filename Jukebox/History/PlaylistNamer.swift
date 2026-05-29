//
//  PlaylistNamer.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Mood-leaning name suggestions for a saved history playlist.

import Foundation

enum PlaylistNamer {
	/// "<phrase> ft. <artist>" when a seed artist is supplied, else the phrase.
	static func suggestedName(seedArtist: String? = nil, at date: Date = Date()) -> String {
		var pool: [String] = [
			"Afterglow",
			"Slow burn",
			"Long shadow",
			"Open windows",
			"Empty rooms",
			"Quiet hours",
			"Soft light",
			"Last call",
			"Warm gray",
			"Holding pattern",
			"Slow trains",
			"Patio weather",
			"Off-peak",
			"After the rain",
			"Front porch",
			"Half-light",
			"No plans",
			"Easy chair",
			"Drift",
			"Slow exhale",
			"Pale orange",
			"After supper",
			"Linen",
			"Soft static",
			"Low ceiling",
			"Long evening",
			"Sleepy Sunday",
			"Tea kettle",
			"Slow river",
			"Window light",
		]
		pool.append(timeOfDayVariant(at: date))
		let phrase = pool.randomElement() ?? "Drift"

		if let artist = seedArtist.flatMap(trimmedArtist), !artist.isEmpty {
			return "\(phrase) ft. \(artist)"
		}
		return phrase
	}

	/// Strips trailing "feat./with" clauses so the result doesn't compose
	/// to "Phrase ft. Foo feat. Bar." Nil when empty.
	private static func trimmedArtist(_ raw: String) -> String? {
		let lowered = raw.lowercased()
		for marker in [" feat.", " feat ", " ft.", " ft ", " featuring ", " with "] {
			if let range = lowered.range(of: marker) {
				let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
				let endIndex = raw.index(raw.startIndex, offsetBy: offset)
				let trimmed = String(raw[..<endIndex]).trimmingCharacters(in: .whitespaces)
				return trimmed.isEmpty ? nil : trimmed
			}
		}
		let trimmed = raw.trimmingCharacters(in: .whitespaces)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static func timeOfDayVariant(at date: Date) -> String {
		let hour = Calendar.current.component(.hour, from: date)
		switch hour {
		case 0 ..< 5: return "Past midnight"
		case 5 ..< 9: return "Pre-dawn"
		case 9 ..< 12: return "Morning glass"
		case 12 ..< 17: return "Afternoon drift"
		case 17 ..< 20: return "Dusk light"
		default: return "Late-night drift"
		}
	}
}
