//
//  DialTunables.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// All visual + motion knobs for the dial. Adjust freely; everything in
/// the dial pipeline reads from here.
enum DialTunables {
	// MARK: - Layout

	/// Degrees of visual rotation per cover transition. Decoupled from
	/// item count — neighbors always sit at this angular spacing.
	static let stepVisual: Double = 20.0
	/// Cover diameter as a fraction of the dial container's smallest
	/// dimension (`min(width, height)`). Equivalent to a square
	/// containerRelativeFrame at this fraction — no hard pt cap, so the
	/// dial scales naturally to any device.
	static let coverSizeRatio: Double = 0.8
	/// Cylinder radius expressed as a multiple of `coverSize`. Larger =
	/// neighbors sit further out toward the screen edges.
	static let cylinderRadiusFactor: Double = 3.25
	/// Neighbors kept alive on each side of the focused cover. Wider than
	/// the visible arc on purpose, so artwork for adjacent covers is
	/// already loaded by the time they rotate into view.
	static let visibleHalf: Int = 3

	// MARK: - Scale

	/// Scale at the absolute center of the dial.
	static let focusedScale: Double = 1
	/// Scale of covers at the back of the cylinder.
	static let edgeScale: Double = 0.30
	/// Sharpness of the scale falloff away from center.
	/// 1 = linear; >1 = focused stays bigger longer.
	static let scaleCurveExponent: Double = 1.5

	// MARK: - 3D feel

	/// Per-cover 3D tilt multiplier. 1 = full tilt (very Cover-Flow),
	/// 0 = no tilt (covers stay flat). Layout offset is unaffected.
	static let rotationDamping: Double = 0.55
	/// `perspective` argument passed to rotation3DEffect.
	static let perspective: Double = 0.6
	/// Continuous wobble amplitude on the focused cover, in degrees.
	static let wobbleAmplitude: Double = 1.5
	/// Wobble period in seconds.
	static let wobblePeriod: Double = 8.0

	// MARK: - Memory

	/// Multiplier on the peak displayed cover size used when requesting
	/// artwork from MusicKit. 1.0 = pixel-exact at peak zoom (sharp);
	/// 0.5 = ¼ the memory per cover but ~2× upsample blur.
	static let artworkRequestRatio: Double = 1.0

	// MARK: - Shuffle

	/// Maximum number of items the shuffle button is allowed to jump
	/// over in a single spin. Keeps random picks within a bounded
	/// neighborhood so the wheel doesn't traverse half the deck on
	/// every press.
	static let maxShuffleJump: Int = 24

	// MARK: - Motion

	/// SwiftUI spring used for every animated wheel transition — drag-snap,
	/// tap-to-focus, shuffle, and the focused cover's shadow/blur crossfade.
	static let wheelSpring: Animation = .spring(duration: 0.6, bounce: 0.28)
	/// Exponent on the superlinear flick-inertia term. The settle
	/// projection is `raw + raw^exponent × boost`: keeps slow flicks at
	/// native scroll feel while amplifying fast ones. Keep above 1.5.
	static let flickInertiaExponent: Double = 2.0
	/// Scale on the superlinear flick-inertia term. 0.0 = pure native
	/// scroll; higher = stronger fast-flick boost.
	static let flickInertiaBoost: Double = 0.3

	// MARK: - Shuffle animation

	/// Bounce parameter on the spring driving the shuffle spin. Lower =
	/// more resistance, less overshoot past the landing detent (so a
	/// long-distance shuffle doesn't briefly carry the focused cover off
	/// to the side before settling). Keep > 0 so it still reads as
	/// springy rather than critically damped.
	static let shuffleSpringBounce: Double = 0.12

	/// Bounded shuffle spin duration as a function of angular distance.
	/// Short hops feel like a flick; longer trips ease out a touch more.
	static func shuffleDuration(degrees distance: Double) -> Double {
		let detents = abs(distance) / stepVisual
		return max(0.5, min(1.4, 0.35 + detents * 0.08))
	}
}
