//
//  DialItemView.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import MusicKit
import SwiftUI

/// A single cover on the dial — the bit that scales, wobbles, blurs, ripples,
/// and casts a shadow. Driven entirely by inputs from `DialContent`; owns its
/// own local ripple state and focus-strength ramp.
struct DialItemView: View {
	let artwork: Artwork?
	let coverSize: Double
	let requestSize: Double
	let radius: Double
	let screenAngle: Angle
	let isFocused: Bool
	/// External "this cover was shuffled to" counter. Distinct from
	/// `rippleTriggerCount` (the local ripple-event counter) because the
	/// shuffle-land origin (bottom center) and a focused-tap origin (the
	/// touch point) feed the same modifier — local state lets both sources
	/// configure origin + bump the trigger in lockstep.
	let rippleTrigger: Int
	let placeholderSymbol: String
	let onTap: () -> Void

	@State private var rippleOrigin: CGPoint = .zero
	@State private var rippleTriggerCount: Int = 0
	/// Eased 0→1 ramp that follows `isFocused`. SwiftUI can't smooth
	/// the wobble's `sin(t*omega)` directly — it's a function of time,
	/// not a value SwiftUI animates between — so we multiply by this
	/// state instead. Wobble amplitude grows in (and dies out) over
	/// the focus transition, and the shadow size rides the same ramp,
	/// so a cover landing at center doesn't pop straight into full
	/// oscillation + heavy shadow.
	@State private var focusStrength: Double

	init(
		artwork: Artwork?,
		coverSize: Double,
		requestSize: Double,
		radius: Double,
		screenAngle: Angle,
		isFocused: Bool,
		rippleTrigger: Int,
		placeholderSymbol: String,
		onTap: @escaping () -> Void
	) {
		self.artwork = artwork
		self.coverSize = coverSize
		self.requestSize = requestSize
		self.radius = radius
		self.screenAngle = screenAngle
		self.isFocused = isFocused
		self.rippleTrigger = rippleTrigger
		self.placeholderSymbol = placeholderSymbol
		self.onTap = onTap
		// Initialise to match isFocused so the first render isn't a
		// one-frame snap (state default would be 0, then onAppear
		// would jump to 1 for a freshly-focused cover).
		_focusStrength = State(initialValue: isFocused ? 1.0 : 0.0)
	}

	var body: some View {
		let radians = screenAngle.radians
		let depth = cos(radians)
		let normalized = max(0, depth)
		let xOffset = sin(radians) * radius
		let scale = DialTunables.edgeScale
			+ (DialTunables.focusedScale - DialTunables.edgeScale)
			* pow(normalized, DialTunables.scaleCurveExponent)
		let blur = (1 - normalized) * 3

		// Keep ticking through the focus-out fade so the wobble can
		// decay smoothly. Once the ramp settles at ~0 and the cover
		// isn't focused, pause to save energy.
		TimelineView(
			.animation(minimumInterval: 1.0 / 30.0, paused: !isFocused && focusStrength < 0.01)
		) { context in
			wobblingCover(at: context.date)
		}
		.rotation3DEffect(
			.degrees(screenAngle.degrees * DialTunables.rotationDamping),
			axis: (x: 0, y: 1, z: 0),
			perspective: DialTunables.perspective
		)
		.offset(x: xOffset)
		.scaleEffect(scale)
		.blur(radius: blur)
		.zIndex(normalized)
		.onChange(of: isFocused) { _, focused in
			withAnimation(.smooth(duration: 0.35)) {
				focusStrength = focused ? 1.0 : 0.0
			}
		}
		.onChange(of: rippleTrigger) { _, _ in
			rippleOrigin = CGPoint(x: coverSize / 2, y: coverSize * 0.9)
			rippleTriggerCount &+= 1
		}
	}

	@ViewBuilder
	private func wobblingCover(at date: Date) -> some View {
		let t = date.timeIntervalSinceReferenceDate
		let omega: Double = 2 * .pi / DialTunables.wobblePeriod
		// Envelope the oscillation with the eased focus ramp so a
		// newly-focused cover doesn't snap straight into ±amplitude.
		let wobbleX: Double = sin(t * omega) * DialTunables.wobbleAmplitude * focusStrength
		let wobbleY: Double = cos(t * omega) * DialTunables.wobbleAmplitude * focusStrength

		// DragGesture-with-slop-threshold instead of .onTapGesture or
		// Button. Button's gesture eats the parent's DragGesture until a
		// hard flick breaks it loose (wheel feels stuck); .onTapGesture
		// composes correctly but fires on any touch-up within iOS's
		// built-in ~10–20pt tap tolerance, which catches gentle dial
		// swipes — the user is trying to scroll but the cover under their
		// finger starts playing. By thresholding manually we get the best
		// of both: tap fires only when the finger really stays put, and
		// the gesture still runs simultaneously with the parent's dial
		// drag (which actually rotates the wheel).
		//
		// RippleEffect is attached BEFORE rotation3DEffect/shadow so the
		// shader's local coordinate space is the cover's own
		// (coverSize × coverSize) frame — same space the gesture location
		// is reported in.
		CoverArtView(
			artwork: artwork,
			width: coverSize,
			requestedWidth: requestSize,
			placeholderSymbol: placeholderSymbol
		)
		.frame(width: coverSize, height: coverSize)
		.modifier(RippleEffect(
			at: rippleOrigin,
			trigger: rippleTriggerCount
		))
		.contentShape(.rect)
		.simultaneousGesture(
			DragGesture(minimumDistance: 0, coordinateSpace: .local)
				.onEnded { value in
					let movement = hypot(value.translation.width, value.translation.height)
					let speed = hypot(value.velocity.width, value.velocity.height)
					// Movement alone isn't enough: during a dial scroll the
					// cover under the finger moves WITH the rotation (covers
					// track the gesture 1:1), so `.local` translation can
					// stay tiny even on a long swipe. The velocity gate
					// catches "finger still moving at release" — a real tap
					// settles to ~0 before the lift, a scroll-release does
					// not. Both must pass for the tap to fire.
					guard movement < 10, speed < 80 else { return }
					if isFocused {
						rippleOrigin = value.location
						rippleTriggerCount &+= 1
					}
					onTap()
				}
		)
		.shadow(
			color: .black.opacity(0.35),
			radius: 10 + 18 * focusStrength,
			y: 6 + 10 * focusStrength
		)
		.rotation3DEffect(.degrees(wobbleX), axis: (x: 1, y: 0, z: 0))
		.rotation3DEffect(.degrees(wobbleY), axis: (x: 0, y: 1, z: 0))
	}
}
