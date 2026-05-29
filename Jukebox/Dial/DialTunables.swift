//
//  DialTunables.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// All visual + motion knobs for the dial. Tune here.
enum DialTunables {
	// MARK: - Layout

	/// Degrees of visual rotation per cover transition (angular neighbor spacing).
	static let stepVisual: Double = 20.0
	/// Cover diameter as a fraction of the container's `min(width, height)`.
	static let coverSizeRatio: Double = 0.8
	/// Cylinder radius as a multiple of `coverSize`. Larger = neighbors further out.
	static let cylinderRadiusFactor: Double = 3.25
	/// Neighbors kept alive per side. Wider than the visible arc on purpose, so
	/// adjacent artwork is loaded before it rotates into view.
	static let visibleHalf: Int = 3

	// MARK: - Scale

	/// Scale at dial center.
	static let focusedScale: Double = 1
	/// Scale at the back of the cylinder.
	static let edgeScale: Double = 0.30
	/// Scale-falloff sharpness. 1 = linear; >1 = focused stays bigger longer.
	static let scaleCurveExponent: Double = 1.5

	// MARK: - 3D feel

	/// Per-cover 3D tilt multiplier. 1 = full Cover-Flow tilt, 0 = flat.
	static let rotationDamping: Double = 0.55
	/// `perspective` argument passed to rotation3DEffect.
	static let perspective: Double = 0.6
	/// Focused-cover wobble amplitude, in degrees.
	static let wobbleAmplitude: Double = 1.5
	/// Wobble period in seconds.
	static let wobblePeriod: Double = 8.0

	// MARK: - Memory

	/// Multiplier on peak cover size when requesting artwork. 1.0 = pixel-exact
	/// at peak zoom; 0.5 = ¼ the memory per cover but ~2× upsample blur.
	static let artworkRequestRatio: Double = 1.0

	// MARK: - Shuffle

	/// Max items shuffle may jump in one spin. Bounded so the wheel doesn't
	/// traverse half the deck per press.
	static let maxShuffleJump: Int = 24

	// MARK: - Motion

	/// Spring for every animated wheel transition (drag-snap, tap, shuffle, crossfade).
	static let wheelSpring: Animation = .spring(duration: 0.6, bounce: 0.28)
	/// Exponent on the flick-inertia term (`raw + raw^exponent × boost`): keeps
	/// slow flicks native while amplifying fast ones. Keep above 1.5.
	static let flickInertiaExponent: Double = 2.0
	/// Scale on the flick-inertia term. 0.0 = pure native scroll; higher = stronger boost.
	static let flickInertiaBoost: Double = 0.3

	// MARK: - Shuffle animation

	/// Bounce on the shuffle-spin spring. Lower = less overshoot past the landing
	/// detent (a long shuffle won't carry the cover off-side before settling).
	/// Keep > 0 so it still reads springy, not critically damped.
	static let shuffleSpringBounce: Double = 0.12

	/// Bounded shuffle-spin duration by angular distance: short hops flick,
	/// long trips ease out more.
	static func shuffleDuration(degrees distance: Double) -> Double {
		let detents = abs(distance) / stepVisual
		return max(0.5, min(1.4, 0.35 + detents * 0.08))
	}
}
