//
//  LibraryStatsSnapshot.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Persisted snapshot of the whole-library overview aggregates. Unlike the
//  other stores this is NOT per-song — the entire `LibraryStats` value
//  (energy buckets, decade histogram, sampled scatter points, top genres,
//  totals) is encoded into one row so the Library Overview sheet can paint
//  the last computed result instantly and revalidate in the background,
//  instead of re-fetching a 10k-song MusicKit union + re-classifying on
//  every open.
//
//  The expensive *inputs* (the union, the embedding vectors) are not cached
//  here — only the small computed *result* (a few hundred counts + ≤1500
//  sampled points). `LibraryStatsBuilder.refresh()` writes it; the warmer's
//  long-tail passes keep the underlying caches growing so successive
//  refreshes resolve a richer picture.
//
//  `modelVersion` invalidates the row when the payload shape or the
//  classification semantics change (centroids, scoring) — a stale snapshot
//  from an older build is treated as a miss and recomputed rather than
//  decoded into the wrong shape. Bump `LibraryStatsStore.currentModelVersion`.

import Foundation
import SwiftData

@Model
final class LibraryStatsSnapshot {
	/// Constant key — the snapshot is whole-library, so there's only ever
	/// one row. `.unique` makes the upsert a straight fetch-or-insert.
	@Attribute(.unique) var key: String
	/// JSON-encoded `LibraryStats`.
	var payload: Data
	var computedAt: Date
	var modelVersion: Int
	/// Coverage at compute time — mirrored out of the payload so freshness
	/// can be compared without decoding the blob.
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
