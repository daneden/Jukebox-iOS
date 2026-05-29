//
//  LibraryStatsSnapshot.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Whole-library overview aggregates encoded into one row (not per-song),
//  so the Library Overview sheet paints instantly and revalidates in the
//  background. Only the small computed result is cached, not the expensive
//  inputs (the union, the embedding vectors).
//
//  `modelVersion` invalidates the row when the payload shape or
//  classification semantics change, so a stale snapshot is recomputed
//  rather than decoded into the wrong shape.

import Foundation
import SwiftData

@Model
final class LibraryStatsSnapshot {
	/// Constant key — whole-library, so only ever one row.
	@Attribute(.unique) var key: String
	/// JSON-encoded `LibraryStats`.
	var payload: Data
	var computedAt: Date
	var modelVersion: Int
	/// Mirrored out of the payload so freshness compares without decoding
	/// the blob.
	var unionCount: Int
	var embeddedCount: Int

	init(
		key: String,
		payload: Data,
		computedAt: Date,
		modelVersion: Int,
		unionCount: Int,
		embeddedCount: Int
	) {
		self.key = key
		self.payload = payload
		self.computedAt = computedAt
		self.modelVersion = modelVersion
		self.unionCount = unionCount
		self.embeddedCount = embeddedCount
	}
}
