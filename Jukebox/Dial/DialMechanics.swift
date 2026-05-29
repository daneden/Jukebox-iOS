//
//  DialMechanics.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import Foundation
import SwiftUI

/// Pure rotation/index/destination arithmetic. No SwiftUI state or animation.
enum DialMechanics {
	/// Rotation that lands `target` at the front via the shortest modular path.
	/// No minimum sweep, so the covers passing through the visible window stay bounded.
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

	/// Random target within `maxShuffleJump` of current focus, either direction.
	/// Bounded so a spin doesn't load half the library's artwork end-to-end.
	static func shuffleTarget(currentFocus: Int, itemCount: Int) -> Int? {
		guard itemCount > 0 else { return nil }
		if itemCount == 1 { return 0 }
		let maxOffset = min(itemCount - 1, DialTunables.maxShuffleJump)
		let magnitude = Int.random(in: 1 ... maxOffset)
		let direction = Bool.random() ? 1 : -1
		return ((currentFocus + magnitude * direction) % itemCount + itemCount) % itemCount
	}

	/// Angle congruent (mod `count`) to `current`, nearest the current position,
	/// re-anchored on `newIdx`. Keeps the same item centered after a reorder
	/// without teleporting the wheel to the modular-zero representative.
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
