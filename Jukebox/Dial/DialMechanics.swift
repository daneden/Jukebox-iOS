//
//  DialMechanics.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import SwiftUI

/// Pure math shared by the dial and the modes that drive it. No SwiftUI
/// state, no animation — just rotation/index/destination arithmetic.
enum DialMechanics {
	/// Rotation that lands `target` at the front via the shortest modular
	/// path. No forced full-rotations, no minimum sweep — the wheel travels
	/// straight to its destination, which keeps the number of covers that
	/// pass through the visible window bounded.
	static func spinDestination(current: Angle, target: Int, count: Int) -> Angle {
		guard count > 0 else { return current }
		let cp = -current.degrees / DialTunables.stepVisual
		var diff = (Double(target) - cp).truncatingRemainder(dividingBy: Double(count))
		let half = Double(count) / 2
		if diff > half { diff -= Double(count) }
		if diff < -half { diff += Double(count) }
		let newCp = cp + diff
		return .degrees(-newCp * DialTunables.stepVisual)
	}

	/// Pick a random target within `maxShuffleJump` of the current focus,
	/// in either direction. Bounded so a spin doesn't have to load half
	/// the library's artwork to cross from one end to the other.
	static func shuffleTarget(currentFocus: Int, itemCount: Int) -> Int? {
		guard itemCount > 0 else { return nil }
		if itemCount == 1 { return 0 }
		let maxOffset = min(itemCount - 1, DialTunables.maxShuffleJump)
		let magnitude = Int.random(in: 1 ... maxOffset)
		let direction = Bool.random() ? 1 : -1
		return ((currentFocus + magnitude * direction) % itemCount + itemCount) % itemCount
	}

	/// Find the angle congruent (mod `count`) to `rotation` that's nearest
	/// to the current position when re-anchoring on `newIdx`. Keeps the
	/// same item centered after a list reorder without teleporting the
	/// wheel to the modular-zero representative.
	static func reanchoredRotation(current: Angle, newIdx: Int, count: Int) -> Angle {
		guard count > 0 else { return current }
		let cp = -current.degrees / DialTunables.stepVisual
		var diff = (Double(newIdx) - cp).truncatingRemainder(dividingBy: Double(count))
		let half = Double(count) / 2
		if diff > half { diff -= Double(count) }
		if diff < -half { diff += Double(count) }
		let newCp = cp + diff
		return .degrees(-newCp * DialTunables.stepVisual)
	}
}
