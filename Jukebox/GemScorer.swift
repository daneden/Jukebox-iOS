//
//  GemScorer.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import MusicKit

/// Pure-function scoring for "hidden gems". Two complementary tracks:
///
/// - **Nostalgia** — songs the user has actually played a lot in the past
///   that have gone quiet. `playCount × dormantMonths`, log-saturated on
///   plays so a 500-play outlier doesn't dominate the whole deck.
/// - **Discovery** — songs added to the library a long time ago and barely
///   touched since. `libraryAgeMonths / (playCount + 1)`.
///
/// Each is scored raw; the caller normalises to [0,1] across the candidate
/// pool and blends them. Recency is a hard filter — anything played in
/// the last `recencyCutoffDays` is excluded entirely.
struct GemScorer {
	let now: Date
	let recencyCutoffDays: Int
	let nostalgiaWeight: Double
	let discoveryWeight: Double

	init(
		now: Date = Date(),
		recencyCutoffDays: Int = 14,
		nostalgiaWeight: Double = 0.70,
		discoveryWeight: Double = 0.30
	) {
		self.now = now
		self.recencyCutoffDays = recencyCutoffDays
		self.nostalgiaWeight = nostalgiaWeight
		self.discoveryWeight = discoveryWeight
	}

	struct RawScores {
		let nostalgia: Double
		let discovery: Double
	}

	/// Returns nil if the song should be excluded outright (played too
	/// recently). Otherwise yields the raw nostalgia + discovery scores.
	func rawScores(for song: Song) -> RawScores? {
		if let last = song.lastPlayedDate,
		   now.timeIntervalSince(last) < TimeInterval(recencyCutoffDays * 86400)
		{
			return nil
		}
		return RawScores(
			nostalgia: nostalgia(song),
			discovery: discovery(song)
		)
	}

	/// log(plays + 1) × min(dormantMonths, 60).
	/// - Zero if never played (nil or 0 playCount) — that's the discovery
	///   track's job.
	/// - Played but no `lastPlayedDate` (rare): treat as 24 months dormant.
	private func nostalgia(_ song: Song) -> Double {
		guard let plays = song.playCount, plays > 0 else { return 0 }
		let dormantMonths: Double = song.lastPlayedDate.map {
			max(0, Self.monthsBetween($0, now))
		} ?? 24
		return log(Double(plays) + 1) * min(dormantMonths, 60)
	}

	/// libraryAgeMonths / (playCount + 1). Zero if we don't know when it
	/// was added.
	private func discovery(_ song: Song) -> Double {
		guard let added = song.libraryAddedDate else { return 0 }
		let ageMonths = max(0, Self.monthsBetween(added, now))
		return ageMonths / (Double(song.playCount ?? 0) + 1)
	}

	static func monthsBetween(_ earlier: Date, _ later: Date) -> Double {
		later.timeIntervalSince(earlier) / (30.44 * 86400)
	}

	/// Score a candidate pool: filter by recency, normalise each track to
	/// [0,1] across the pool, blend with weights, sort descending, return
	/// `(song, score)` pairs.
	func scoreAndRank(_ songs: [Song]) -> [(song: Song, score: Double)] {
		let raw: [(Song, Double, Double)] = songs.compactMap { song in
			guard let s = rawScores(for: song) else { return nil }
			return (song, s.nostalgia, s.discovery)
		}
		guard !raw.isEmpty else { return [] }
		let nMax = max(raw.map(\.1).max() ?? 1, 1e-9)
		let dMax = max(raw.map(\.2).max() ?? 1, 1e-9)
		let scored = raw.map { song, n, d in
			(song: song, score: nostalgiaWeight * (n / nMax) + discoveryWeight * (d / dMax))
		}
		return scored.sorted { $0.score > $1.score }
	}
}
