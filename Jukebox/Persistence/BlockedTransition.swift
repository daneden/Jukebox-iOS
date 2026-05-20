//
//  BlockedTransition.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  A song pair the user has flagged as "don't put these next to each
//  other again." Stored symmetrically — the pair key is the two song
//  IDs sorted and joined, so we don't double-store a pair in both
//  directions and the walk can check membership in O(1).
//
//  Soft preference, not a hard contract: if the walk can't find any
//  unblocked candidate, it falls through to picking one rather than
//  deadlocking the deck.

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
