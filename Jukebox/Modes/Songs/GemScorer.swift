//
//  GemScorer.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import MusicKit

/// Pure-function scoring for "hidden gems". Three complementary tracks:
///
/// - **Nostalgia** — heavily-played songs gone quiet. `playCount ×
///   dormantMonths`, log-saturated on plays so a 500-play outlier doesn't
///   dominate the deck.
/// - **Discovery** — songs added long ago and barely touched.
///   `libraryAgeMonths / (playCount + 1)`.
/// - **Freshness** — recently-added songs with a few plays that drifted
///   off rotation. The gap the other two miss: nostalgia wants high
///   playCount, discovery wants long tenure.
///
/// Each is scored raw; the caller normalises to [0,1] across the pool and
/// blends. Recency is a soft multiplier (`recencyFloor` at days-since=0,
/// recovering linearly to 1.0 at `recencyCutoffDays`) — hard exclusion
/// was too aggressive for small libraries inside a 14-day window.
/// Unplayable songs (nil playParameters) are still hard-excluded.
struct GemScorer {
	let now: Date
	let recencyCutoffDays: Int
	let nostalgiaWeight: Double
	let discoveryWeight: Double
	let freshnessWeight: Double
	/// Score multiplier at "played right now". 0.1 = just-played songs
	/// score 10%, strongly deprioritised but reachable; 0 would replicate
	/// the old hard exclusion.
	let recencyFloor: Double
	/// Per-song most-recent play date from our own log, max()'d with
	/// `Song.lastPlayedDate` inside `recencyPenalty`.
	let recentPlays: [String: Date]

	init(
		now: Date = Date(),
		recencyCutoffDays: Int = 14,
		nostalgiaWeight: Double = 0.50,
		discoveryWeight: Double = 0.25,
		freshnessWeight: Double = 0.25,
		recencyFloor: Double = 0.1,
		recentPlays: [String: Date] = [:]
	) {
		self.now = now
		self.recencyCutoffDays = recencyCutoffDays
		self.nostalgiaWeight = nostalgiaWeight
		self.discoveryWeight = discoveryWeight
		self.freshnessWeight = freshnessWeight
		self.recencyFloor = recencyFloor
		self.recentPlays = recentPlays
	}

	struct RawScores {
		let nostalgia: Double
		let discovery: Double
		let freshness: Double
	}

	/// Returns nil only when the song can't be played at all.
	func rawScores(for song: Song) -> RawScores? {
		// `playParameters == nil` → SystemMusicPlayer silently skips it in
		// the queue (rights lapsed, no cloud match, region-locked). Filter
		// outright so it never reaches the deck.
		if song.playParameters == nil { return nil }

		let penalty = recencyPenalty(for: song)
		return RawScores(
			nostalgia: nostalgia(song) * penalty,
			discovery: discovery(song) * penalty,
			freshness: freshness(song) * penalty
		)
	}

	/// Linear ramp from `recencyFloor` at days-since=0 to 1.0 at
	/// `recencyCutoffDays`. Uses the max of `lastPlayedDate` and our
	/// HistoryStore date because MusicKit's lags for SystemMusicPlayer.
	private func recencyPenalty(for song: Song) -> Double {
		let candidate = max(
			song.lastPlayedDate ?? .distantPast,
			recentPlays[song.id.rawValue] ?? .distantPast
		)
		let daysSince = now.timeIntervalSince(candidate) / 86400.0
		if daysSince <= 0 { return recencyFloor }
		if daysSince >= Double(recencyCutoffDays) { return 1.0 }
		return recencyFloor + (1.0 - recencyFloor) * (daysSince / Double(recencyCutoffDays))
	}

	/// log(plays + 1) × min(dormantMonths, 60). Zero if never played
	/// (that's discovery's job); played-but-no-`lastPlayedDate` is treated
	/// as 24 months dormant.
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

	/// exp(-daysSinceAdded / 90) × min(1, log(plays+1)) × dormantWeeks —
	/// three multiplicative gates:
	///  - `exp(-daysSinceAdded / 90)` — ~90-day half-life on add recency.
	///  - `min(1, log(plays+1))` — must have ≥1 play; saturates at ~2 so a
	///    discovery binge doesn't over-rank.
	///  - `dormantWeeks` — bounded by library tenure so a never-played
	///    song doesn't accrue a bogus dormant window via MusicKit's
	///    `lastPlayedDate` defaulting.
	///
	/// Zero when never played or no `libraryAddedDate`.
	private func freshness(_ song: Song) -> Double {
		guard let added = song.libraryAddedDate else { return 0 }
		guard let plays = song.playCount, plays > 0 else { return 0 }

		let daysSinceAdded = max(0, now.timeIntervalSince(added) / 86400.0)
		let lastPlayed = song.lastPlayedDate ?? added
		let rawDormant = now.timeIntervalSince(lastPlayed) / 86400.0
		let dormantDays = max(0, min(daysSinceAdded, rawDormant))
		let dormantWeeks = dormantDays / 7.0

		let recencyOfAdd = exp(-daysSinceAdded / 90.0)
		let playSignal = min(1.0, log(Double(plays) + 1))
		return recencyOfAdd * playSignal * dormantWeeks
	}

	static func monthsBetween(_ earlier: Date, _ later: Date) -> Double {
		later.timeIntervalSince(earlier) / (30.44 * 86400)
	}

	/// Score a candidate pool: normalise each track to [0,1] across the
	/// pool, blend with weights, sort descending.
	func scoreAndRank(_ songs: [Song]) -> [(song: Song, score: Double)] {
		let raw: [(Song, Double, Double, Double)] = songs.compactMap { song in
			guard let s = rawScores(for: song) else { return nil }
			return (song, s.nostalgia, s.discovery, s.freshness)
		}
		guard !raw.isEmpty else { return [] }
		let nMax = max(raw.map(\.1).max() ?? 1, 1e-9)
		let dMax = max(raw.map(\.2).max() ?? 1, 1e-9)
		let fMax = max(raw.map(\.3).max() ?? 1, 1e-9)
		let scored = raw.map { song, n, d, f in
			(
				song: song,
				score: nostalgiaWeight * (n / nMax)
					+ discoveryWeight * (d / dMax)
					+ freshnessWeight * (f / fMax)
			)
		}
		return scored.sorted { $0.score > $1.score }
	}
}
