//
//  SongEmbedding.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Per-song audio embedding cached on disk via SwiftData; embedding a song
//  costs ~1s of preview download + AudioFeaturePrint inference, so re-embedding
//  every cold launch is a non-starter.
//
//  `modelVersion` invalidates the cache if the embedding model changes; bump
//  the constant in EmbeddingStore and old rows are treated as misses on read.
//
//  `bpm` + `bpmConfidence`: nil means a legacy row or audio that defeated the
//  detector. The walk treats missing BPM as "no signal", so legacy rows are
//  left alone rather than forced to re-download for backfill.
//
//  `bpmModelVersion` versions the BPM independently of `modelVersion` so a
//  better tempo algorithm doesn't invalidate the expensive embedding vector.
//  Non-optional scalar with a default literal keeps SwiftData migration
//  lightweight — existing rows backfill 0 in place, vectors preserved.

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
