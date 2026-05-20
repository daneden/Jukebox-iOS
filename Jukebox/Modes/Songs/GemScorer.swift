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
/// pool and blends them. Recency is now a soft multiplier — songs played
/// today get `recencyFloor` (default 0.1, i.e. 10× downranked but still
/// reachable), recovering linearly to no penalty at `recencyCutoffDays`.
/// Hard exclusion was too aggressive for small libraries where the user
/// could play through a meaningful fraction of the candidate pool inside
/// a 14-day window. Unplayable songs (nil playParameters) are still hard-
/// excluded because there's no point ranking something we can't play.
struct GemScorer {
	let now: Date
	let recencyCutoffDays: Int
	let nostalgiaWeight: Double
	let discoveryWeight: Double
	/// Score multiplier at "played right now." 0.1 means recently-
	/// played songs score at 10% of what they'd otherwise score —
	/// strongly deprioritised but not impossible. Anything between
	/// 0 and 1; 0 would replicate the old hard-exclusion behaviour.
	let recencyFloor: Double
	/// Per-song most-recent play date from our own log. Combined with
	/// MusicKit's `Song.lastPlayedDate` via max() inside
	/// `recencyPenalty` — we use whichever signal is more recent.
	let recentPlays: [String: Date]

	init(
		now: Date = Date(),
		recencyCutoffDays: Int = 14,
		nostalgiaWeight: Double = 0.70,
		discoveryWeight: Double = 0.30,
		recencyFloor: Double = 0.1,
		recentPlays: [String: Date] = [:]
	) {
		self.now = now
		self.recencyCutoffDays = recencyCutoffDays
		self.nostalgiaWeight = nostalgiaWeight
		self.discoveryWeight = discoveryWeight
		self.recencyFloor = recencyFloor
		self.recentPlays = recentPlays
	}

	struct RawScores {
		let nostalgia: Double
		let discovery: Double
	}

	/// Returns nil only when the song can't be played at all. Recency is
	/// folded into the scores via a multiplier rather than gating
	/// eligibility outright.
	func rawScores(for song: Song) -> RawScores? {
		// `playParameters == nil` means SystemMusicPlayer will silently
		// skip past this song when it lands in the queue (rights lapsed,
		// non-catalog library item with no cloud match, region-locked,
		// etc). Filter outright so it never reaches the deck.
		if song.playParameters == nil { return nil }

		let penalty = recencyPenalty(for: song)
		return RawScores(
			nostalgia: nostalgia(song) * penalty,
			discovery: discovery(song) * penalty
		)
	}

	/// Linear ramp from `recencyFloor` at days-since-play=0 up to 1.0 at
	/// `recencyCutoffDays`. Uses the max of MusicKit's lastPlayedDate
	/// and our own HistoryStore-derived date because MusicKit's lags
	/// (or never updates) for SystemMusicPlayer plays.
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
