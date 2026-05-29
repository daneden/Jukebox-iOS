//
//  EnergyCurve.swift
//  Jukebox
//
//  Five-control-point energy curve. X is time (left → right), Y is
//  energy (bottom = glacial, top = intense), with X fixed at evenly
//  spaced fractions so it's sampleable at any t in [0, 1].
//

import Foundation
import SwiftUI

struct EnergyCurve: Equatable, Codable {
	/// Y values in [0, 1] at the fixed control X positions. Index i sits
	/// at x = i / (count - 1).
	var points: [Double]

	static let pointCount = 5

	/// Catmull-Rom interpolation through the five Y values — passes through
	/// every anchor, so what the user dragged is what they get. Endpoints
	/// reflect the missing neighbour (P_-1 = 2·P0 - P1). Computed via the
	/// cubic-Bézier conversion (identical math) so the on-screen Path
	/// stroke and the sampled energy stay in lockstep.
	func sample(at t: Double) -> Double {
		guard points.count == Self.pointCount else { return 0.5 }
		let segments = Self.pointCount - 1
		let clamped = min(1, max(0, t))
		let scaled = clamped * Double(segments)
		var segIdx = Int(scaled.rounded(.down))
		if segIdx >= segments { segIdx = segments - 1 }
		let localT = max(0, min(1, scaled - Double(segIdx)))

		let p1 = points[segIdx]
		let p2 = points[segIdx + 1]
		let pPrev = segIdx == 0 ? (2 * p1 - p2) : points[segIdx - 1]
		let pNext = segIdx == segments - 1 ? (2 * p2 - p1) : points[segIdx + 2]

		let b1 = p1 + (p2 - pPrev) / 6
		let b2 = p2 - (pNext - p1) / 6

		let s = 1 - localT
		let y = s * s * s * p1
			+ 3 * s * s * localT * b1
			+ 3 * s * localT * localT * b2
			+ localT * localT * localT * p2
		return min(1, max(0, y))
	}

	/// Gentle ramp from low to high so first-time users see a curve that
	/// does something meaningful.
	static let `default` = EnergyCurve(points: [0.1, 0.3, 0.5, 0.75, 0.9])

	static func random() -> EnergyCurve {
		EnergyCurve(points: (0 ..< pointCount).map { _ in Double.random(in: 0.05 ... 0.95) })
	}
}

extension EnergyBand {
	/// Concrete bands ordered low → high, for band-ordered iteration.
	static let concreteOrdered: [EnergyBand] = [.glacial, .mellow, .energetic, .intense]
}
