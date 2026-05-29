//
//  BlockedTransition.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  A song pair flagged as "don't put these next to each other again."
//  Pair key is the two IDs sorted and joined, so storage is symmetric
//  and membership is O(1).
//
//  Soft preference: if no unblocked candidate exists, the walk picks one
//  anyway rather than deadlocking the deck.

import Foundation
import SwiftData

@Model
final class BlockedTransition {
	@Attribute(.unique) var pairKey: String
	var songIDA: String
	var songIDB: String
	var blockedAt: Date

	init(songIDA: String, songIDB: String) {
		let sorted = [songIDA, songIDB].sorted()
		pairKey = sorted.joined(separator: "|")
		self.songIDA = sorted[0]
		self.songIDB = sorted[1]
		blockedAt = Date()
	}
}
