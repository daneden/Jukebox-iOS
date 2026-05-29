//
//  DialItemView.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import MusicKit
import SwiftUI

/// A single cover on the dial: scales, wobbles, blurs, ripples, casts a shadow.
struct DialItemView: View {
	let artwork: Artwork?
	let coverSize: Double
	let requestSize: Double
	let radius: Double
	let screenAngle: Angle
	let isFocused: Bool
	/// External "shuffled to here" counter. Separate from `rippleTriggerCount`
	/// so shuffle-land (bottom center) and focused-tap (touch point) origins can
	/// both feed the same modifier.
	let rippleTrigger: Int
	let placeholderSymbol: String
	let onTap: () -> Void

	@State private var rippleOrigin: CGPoint = .zero
	@State private var rippleTriggerCount: Int = 0
	/// Eased 0→1 ramp following `isFocused`. SwiftUI can't smooth the wobble's
	/// time-based `sin(t*omega)` directly, so we multiply by this; wobble and
	/// shadow ride it in, so a landing cover doesn't pop into full oscillation.
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
		// Match isFocused up front so the first render isn't a one-frame snap.
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

		// Keep ticking through the focus-out fade so the wobble decays
		// smoothly; pause once settled and unfocused to save energy.
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
		// Envelope by the focus ramp so a newly-focused cover doesn't
		// snap straight into ±amplitude.
		let wobbleX: Double = sin(t * omega) * DialTunables.wobbleAmplitude * focusStrength
		let wobbleY: Double = cos(t * omega) * DialTunables.wobbleAmplitude * focusStrength

		// Thresholded DragGesture, not .onTapGesture or Button: Button eats the
		// parent dial drag (wheel feels stuck), and .onTapGesture fires within
		// iOS's ~10–20pt tap tolerance, so gentle scroll swipes start playback.
		//
		// RippleEffect is attached BEFORE rotation3DEffect/shadow so the shader's
		// local space is the cover's own frame — same space as the gesture location.
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
					// Movement alone isn't enough: covers track the dial 1:1, so
					// `.local` translation stays tiny even on a long swipe. The
					// velocity gate catches "finger still moving at release";
					// both must pass for the tap to fire.
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
