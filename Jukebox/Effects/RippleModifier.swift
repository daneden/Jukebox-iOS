//
//  RippleModifier.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import SwiftUI

struct RippleModifier: ViewModifier {
	var origin: CGPoint

	var elapsedTime: TimeInterval

	var duration: TimeInterval

	var amplitude: Double
	var frequency: Double
	var decay: Double
	var speed: Double

	func body(content: Content) -> some View {
		let shader = ShaderLibrary.Ripple(
			.float2(origin),
			.float(elapsedTime),

			.float(amplitude),
			.float(frequency),
			.float(decay),
			.float(speed)
		)

		let maxSampleOffset = maxSampleOffset
		let elapsedTime = elapsedTime
		let duration = duration

		content.visualEffect { view, _ in
			view.layerEffect(
				shader,
				maxSampleOffset: maxSampleOffset,
				isEnabled: elapsedTime > 0 && elapsedTime < duration
			)
		}
	}

	var maxSampleOffset: CGSize {
		CGSize(width: amplitude, height: amplitude)
	}
}

struct RippleEffect<T: Equatable>: ViewModifier {
	var origin: CGPoint
	var trigger: T
	var amplitude: Double
	var frequency: Double
	var decay: Double
	var speed: Double

	init(at origin: CGPoint, trigger: T, amplitude: Double = 12, frequency: Double = 15, decay: Double = 8, speed: Double = 1200) {
		self.origin = origin
		self.trigger = trigger
		self.amplitude = amplitude
		self.frequency = frequency
		self.decay = decay
		self.speed = speed
	}

	func body(content: Content) -> some View {
		let origin = origin
		let duration = duration
		let amplitude = amplitude
		let frequency = frequency
		let decay = decay
		let speed = speed

		content.keyframeAnimator(
			initialValue: 0,
			trigger: trigger
		) { view, elapsedTime in
			view.modifier(RippleModifier(
				origin: origin,
				elapsedTime: elapsedTime,
				duration: duration,
				amplitude: amplitude,
				frequency: frequency,
				decay: decay,
				speed: speed
			))
		} keyframes: { _ in
			MoveKeyframe(0)
			LinearKeyframe(duration, duration: duration)
		}
	}

	var duration: TimeInterval {
		3
	}
}
