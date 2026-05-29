//
//  EmbeddingFailure.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Negative cache for songs `AudioEmbeddingService` couldn't embed.
//  The warmer iterates ~10k songs per pass; without this it would retry
//  the same hopeless songs forever, burning the WiFi/battery budget.
//
//  Only *permanent* failures are recorded (`noCatalogMatch`, `noPreview`,
//  `emptyOutput`); transient ones (timeouts, drops) are left to retry.
//  Honoured for `LibraryEmbeddingWarmer.failureRetryAfter`, then retried
//  in case Apple's catalog improved.
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
