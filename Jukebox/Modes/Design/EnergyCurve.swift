//
//  EnergyCurve.swift
//  Jukebox
//
//  Five-control-point energy curve. X is time (left → right), Y is
//  energy (bottom = glacial, top = intense). Control points' X
//  positions are fixed at evenly spaced fractions {0, 0.25, 0.5, 0.75,
//  1.0} so the curve is a quartic (degree-4) Bézier in Y — sampleable
//  at any t in [0, 1] with the standard Bernstein basis.
//
//  Persisted as five Double values in @AppStorage rather than a JSON
//  blob so the keys stay debuggable and a future field addition can
//  migrate without a custom decoder.
//

import Foundation
import SwiftUI

struct EnergyCurve: Equatable, Codable {
	/// Y values in [0, 1] at the fixed control X positions. Index i sits
	/// at x = i / (count - 1).
	var points: [Double]

	static let pointCount = 5

	/// Quartic Bézier on the five Y values. Returned value is clamped to
	/// [0, 1] — degree-4 evaluation can drift fractions of a percent
	/// outside the convex hull due to float rounding, and the EnergyBand
	/// mapping relies on a clean [0, 1] domain.
	func sample(at t: Double) -> Double {
		guard points.count == Self.pointCount else { return 0.5 }
		let s = 1 - t
		let s2 = s * s
		let s3 = s2 * s
		let s4 = s3 * s
		let t2 = t * t
		let t3 = t2 * t
		let t4 = t3 * t
		let y = s4 * points[0]
			+ 4 * s3 * t * points[1]
			+ 6 * s2 * t2 * points[2]
			+ 4 * s * t3 * points[3]
			+ t4 * points[4]
		return min(1, max(0, y))
	}

	/// Default shape: a gentle ramp from low to high energy so first-time
	/// users immediately see a curve that does something meaningful.
	static let `default` = EnergyCurve(points: [0.1, 0.3, 0.5, 0.75, 0.9])

	static func random() -> EnergyCurve {
		EnergyCurve(points: (0 ..< pointCount).map { _ in Double.random(in: 0.05 ... 0.95) })
	}
}

extension EnergyBand {
	/// Map a [0, 1] curve sample into one of the four energy bands.
	/// Buckets are equal-width (0.25 each); cleanly splits the four
	/// bands across the full vertical extent of the editor. `.any`
	/// is intentionally unreachable here — Design mode commits to a
	/// concrete band per song.
	static func forCurveValue(_ y: Double) -> EnergyBand {
		switch y {
		case ..<0.25: .glacial
		case ..<0.5: .mellow
		case ..<0.75: .energetic
		default: .intense
		}
	}

	/// Concrete bands ordered low → high, used for nearest-band fallback
	/// when the requested band's candidate pool is empty.
	static let concreteOrdered: [EnergyBand] = [.glacial, .mellow, .energetic, .intense]
}
