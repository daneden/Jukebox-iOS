//
//  SongEmbedding.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Per-song audio embedding cached on disk via SwiftData. ~2KB per row
//  (512 × Float32). For a 300-song gem deck that's ~600KB total — the
//  cache is "free" in storage terms but priceless in time: embedding a
//  song takes ~1s of preview download + AudioFeaturePrint inference,
//  and re-embedding 300 songs every cold launch would be unacceptable.
//
//  `modelVersion` lets us invalidate the cache cleanly if we swap the
//  embedding model later (e.g. AudioFeaturePrint → CLAP). Bump the
//  constant in EmbeddingStore and old entries are ignored on read,
//  treated as misses; they get overwritten on the next embed.
//
//  `bpm` + `bpmConfidence` are populated by `BPMDetector` during the
//  same embed pass, sharing the preview download. Nil for both means
//  either a legacy row (embedded before BPM detection landed) or a
//  song whose audio defeated the detector (ambient, classical,
//  free-time). The walk treats missing BPM as "no signal" rather
//  than a penalty, so we leave legacy rows alone instead of forcing
//  a re-download for backfill.
//
//  `bpmModelVersion` versions the BPM *independently* of `modelVersion`:
//  improving the tempo algorithm shouldn't invalidate the (expensive)
//  embedding vector. The warmer re-detects rows below the current BPM
//  version in the background, overwriting in place — reads keep serving
//  the old value until then, so there's no coverage blackout. Default 0
//  = legacy / detector v0. Non-optional scalar with a default literal:
//  the lightweight (automatic) SwiftData migration case — existing rows
//  backfill 0 in place, no migration plan, vectors preserved.

import Foundation
import SwiftData

@Model
final class SongEmbedding {
	@Attribute(.unique) var songID: String
	var vector: Data
	var modelVersion: Int
	var computedAt: Date
	var bpm: Double?
	var bpmConfidence: Float?
	var bpmModelVersion: Int = 0

	init(
		songID: String,
		vector: Data,
		modelVersion: Int,
		computedAt: Date,
		bpm: Double? = nil,
		bpmConfidence: Float? = nil,
		bpmModelVersion: Int = 0
	) {
		self.songID = songID
		self.vector = vector
		self.modelVersion = modelVersion
		self.computedAt = computedAt
		self.bpm = bpm
		self.bpmConfidence = bpmConfidence
		self.bpmModelVersion = bpmModelVersion
	}
}
