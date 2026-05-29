//
//  DialState.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// All wheel-position state in one bundle, so both modes share the same shape.
///
/// Plain value type, not Observable, so `withAnimation { dial.rotation = … }`
/// works like updating a primitive `@State`.
struct DialState {
	var rotation: Angle = .zero
	var focusedIndex: Int = 0
	var focusedItemID: MusicItemID?
	/// Bumped when a shuffle lands. Drives the `.impact` haptic.
	var spinLandTick: Int = 0
	var isSpinning: Bool = false
	/// Per-item RippleEffect trigger, bumped when a cover starts playing (not
	/// when the wheel lands), so only the played item ripples.
	var rippleCounters: [MusicItemID: Int] = [:]
	/// Bumped once per playback start. Drives the playback-start haptic.
	/// Scalar (vs per-item `rippleCounters`) so one `.sensoryFeedback` observer suffices.
	var playbackTick: Int = 0

	/// Mark a shuffle landing: record focus + tick the spin-land haptic. Does
	/// **not** ripple or fire the playback haptic (those are `markPlaying(id:)`),
	/// so a shuffle without autoplay lands silently on the visual.
	mutating func recordLanding(at index: Int, id: MusicItemID) {
		focusedIndex = index
		focusedItemID = id
		spinLandTick &+= 1
	}

	/// Signal that `id` has started playing: ripple that cover + tick the playback
	/// haptic. Call from the play paths once `SystemMusicPlayer.play()` has returned.
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

	/// Re-anchor focus on a known index after a collection update, without
	/// teleporting the wheel.
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
