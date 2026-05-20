//
//  DialState.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// All wheel-position state in one bundle, so both modes share the same
/// shape. The mode owns `@State private var dial = DialState()`, hands
/// bindings into `DialView`, and calls the mutating methods at the right
/// animation boundaries.
///
/// Plain value type — not Observable — so `withAnimation { dial.rotation = … }`
/// works exactly like updating a primitive `@State`.
struct DialState {
	var rotation: Angle = .zero
	var focusedIndex: Int = 0
	var focusedItemID: MusicItemID?
	/// Bumped each time a shuffle lands. Drives the `.impact` haptic.
	var spinLandTick: Int = 0
	var isSpinning: Bool = false
	/// Per-item RippleEffect trigger. Bumped when a cover actually starts
	/// playing — not when the wheel lands. Each cover reads its own entry
	/// so only the played item ripples.
	var rippleCounters: [MusicItemID: Int] = [:]
	/// Bumped once per playback start. Drives the playback-start haptic.
	/// Separate from `rippleCounters` (which is per-item) so a single
	/// `.sensoryFeedback` observer can watch a scalar.
	var playbackTick: Int = 0

	/// Mark a shuffle landing: record the focused id and tick the spin-land
	/// haptic. Does **not** ripple or fire the playback haptic — both of
	/// those are reserved for `markPlaying(id:)`, so a shuffle without
	/// autoplay lands silently on the visual.
	mutating func recordLanding(at index: Int, id: MusicItemID) {
		focusedIndex = index
		focusedItemID = id
		spinLandTick &+= 1
	}

	/// Signal that `id` has actually started playing: ripple that one
	/// cover and tick the global playback haptic. Call from the play
	/// paths once `SystemMusicPlayer.play()` has returned.
	mutating func markPlaying(id: MusicItemID) {
		rippleCounters[id, default: 0] &+= 1
		playbackTick &+= 1
	}

	/// Reset to a clean state when items go empty.
	mutating func clear() {
		focusedIndex = 0
		rotation = .zero
		focusedItemID = nil
	}

	/// Re-anchor focus on a known index after a collection update. Uses
	/// `DialMechanics.reanchoredRotation` so the wheel doesn't teleport.
	mutating func reanchor(to newIdx: Int, newID: MusicItemID, count: Int) {
		rotation = DialMechanics.reanchoredRotation(
			current: rotation,
			newIdx: newIdx,
			count: count
		)
		focusedIndex = newIdx
		focusedItemID = newID
	}
}
