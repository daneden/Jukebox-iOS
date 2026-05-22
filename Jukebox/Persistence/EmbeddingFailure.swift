//
//  EmbeddingFailure.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Negative cache for songs `AudioEmbeddingService` couldn't resolve to
//  an audio embedding. The library warmer iterates ~10k songs per pass;
//  without this record it would retry the same `noCatalogMatch` /
//  `noPreview` songs every pass forever, burning the WiFi/battery budget
//  on work that will never succeed.
//
//  Only *permanent* failures are recorded — `noCatalogMatch`,
//  `noPreview`, `emptyOutput`. Transient ones (download timeouts,
//  network drops) are left alone so the next pass retries them. We
//  honour the failure for `LibraryEmbeddingWarmer.failureRetryAfter`
//  (currently 60 days) then re-try in case Apple's catalog improved.
//

import Foundation
import SwiftData

@Model
final class EmbeddingFailure {
	@Attribute(.unique) var songID: String
	var failedAt: Date
	var reason: String

	init(songID: String, failedAt: Date, reason: String) {
		self.songID = songID
		self.failedAt = failedAt
		self.reason = reason
	}
}
