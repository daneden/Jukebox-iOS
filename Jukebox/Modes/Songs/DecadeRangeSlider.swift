//
//  DecadeRangeSlider.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Two-thumb range slider for picking a decade interval. SwiftUI's
//  native Slider is single-value through iOS 26, so the dual-thumb
//  behaviour is hand-rolled: thumbs in a ZStack at calculated offsets,
//  drag gestures in a named coordinate space so the touch math
//  survives the offsets. Snap to decade boundaries, thumbs can't
//  cross, both thumbs expose `.accessibilityAdjustableAction` for
//  VoiceOver.
//

import SwiftUI

struct DecadeRangeSlider: View {
	@Binding var range: DecadeRange
	/// Effective bounds for the slider's thumbs. When nil, fall back
	/// to the universal 1900–2030 range. Caller usually derives these
	/// from the user's actual library so the slider's travel matches
	/// reality.
	var bounds: ClosedRange<Int>?

	// Thumb is a capsule, 2× wider than tall — keeps the silhouette
	// distinct from the round Play/Shuffle buttons next to it while
	// still reading as a draggable handle.
	private static let thumbWidth: CGFloat = 40
	private static let thumbHeight: CGFloat = 20
	private static let trackHeight: CGFloat = 4
	private static let coordinateSpaceName = "DecadeRangeSliderTrack"

	// Per-thumb interaction state — drives the inner white fill's
	// opacity so the glass underneath shows through while the thumb
	// is being touched. `@GestureState` auto-resets when the gesture
	// ends or is cancelled (more reliable than tracking with @State).
	@GestureState private var lowerActive = false
	@GestureState private var upperActive = false

	private var effectiveBounds: ClosedRange<Int> {
		bounds ?? (DecadeRange.minDecade ... DecadeRange.maxDecade)
	}

	private var spanDecades: Int {
		effectiveBounds.upperBound - effectiveBounds.lowerBound
	}

	/// Range clamped into the slider's effective bounds — used for
	/// thumb positioning so a saved value from a prior, broader
	/// library window doesn't push the thumb off-track.
	private var clampedRange: DecadeRange {
		let lo = max(effectiveBounds.lowerBound, min(effectiveBounds.upperBound, range.lower))
		let hi = max(effectiveBounds.lowerBound, min(effectiveBounds.upperBound, range.upper))
		return DecadeRange(lower: min(lo, hi), upper: max(lo, hi))
	}

	private var isAtBounds: Bool {
		clampedRange.lower <= effectiveBounds.lowerBound
			&& clampedRange.upper >= effectiveBounds.upperBound
	}

	var body: some View {
		VStack(spacing: 6) {
			HStack {
				Text(formatDecade(clampedRange.lower))
				Spacer()
				Text(formatDecade(clampedRange.upper))
			}
			.font(.callout.monospacedDigit().weight(.medium))
			.foregroundStyle(isAtBounds ? .secondary : .primary)

			GeometryReader { geo in
				track(in: geo.size.width)
			}
			.frame(height: Self.thumbHeight)
			.coordinateSpace(name: Self.coordinateSpaceName)
		}
	}

	private func track(in width: CGFloat) -> some View {
		let usable = max(0, width - Self.thumbWidth)
		let lowerX = position(for: clampedRange.lower, usable: usable)
		let upperX = position(for: clampedRange.upper, usable: usable)

		return ZStack(alignment: .leading) {
			Capsule()
				.fill(.quaternary)
				.frame(height: Self.trackHeight)
				.padding(.horizontal, Self.thumbWidth / 2)

			Capsule()
				.fill(.tint)
				.frame(width: max(0, upperX - lowerX), height: Self.trackHeight)
				.offset(x: lowerX + Self.thumbWidth / 2)

			GlassEffectContainer {
				ZStack(alignment: .leading) {
					thumb(active: lowerActive)
						.offset(x: lowerX)
						.gesture(
							DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
								.updating($lowerActive) { _, state, _ in state = true }
								.onChanged { value in handleDrag(value: value, usable: usable, isLower: true) }
						)
						.accessibilityElement()
						.accessibilityLabel("Decade range start")
						.accessibilityValue(formatDecade(clampedRange.lower))
						.accessibilityAdjustableAction { direction in
							adjust(isLower: true, increment: direction == .increment)
						}

					thumb(active: upperActive)
						.offset(x: upperX)
						.gesture(
							DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
								.updating($upperActive) { _, state, _ in state = true }
								.onChanged { value in handleDrag(value: value, usable: usable, isLower: false) }
						)
						.accessibilityElement()
						.accessibilityLabel("Decade range end")
						.accessibilityValue(formatDecade(clampedRange.upper))
						.accessibilityAdjustableAction { direction in
							adjust(isLower: false, increment: direction == .increment)
						}
				}
			}
		}
	}

	private func thumb(active: Bool) -> some View {
		// `.glassEffect(.clear.interactive(), in: .capsule)` lays the
		// Liquid Glass material behind the thumb and gives the
		// shimmer/bounce response on touch. The white fill rides on
		// top of the glass; it drops to 0% on active so the glass
		// material reads clean during the drag.
		//
		// `scaleEffect` (not a literal frame change) doubles the
		// thumb on press without re-laying-out its position — the
		// .offset that places it on the track stays anchored to the
		// thumb's centre. Spring is intentionally bouncy.
		Capsule()
			.fill(.white)
			.opacity(active ? 0 : 1)
			.frame(width: Self.thumbWidth, height: Self.thumbHeight)
			.glassEffect(.clear.interactive(), in: .capsule)
			.scaleEffect(active ? 1.5 : 1)
			.animation(.spring(duration: 0.45, bounce: 0.45), value: active)
	}

	private func position(for decade: Int, usable: CGFloat) -> CGFloat {
		guard spanDecades > 0 else { return 0 }
		let fraction = Double(decade - effectiveBounds.lowerBound) / Double(spanDecades)
		return CGFloat(fraction) * usable
	}

	// `minimumDistance: 0` on the inline DragGesture so a touch-down
	// on the thumb starts tracking immediately. Named coordinate
	// space is anchored on the GeometryReader, so `location.x` is in
	// the track's frame regardless of which thumb's gesture is
	// firing.
	private func handleDrag(value: DragGesture.Value, usable: CGFloat, isLower: Bool) {
		let touchX = value.location.x - Self.thumbWidth / 2
		let clampedX = max(0, min(usable, touchX))
		let fraction = usable > 0 ? Double(clampedX / usable) : 0
		let stops = max(1, spanDecades / DecadeRange.step)
		let stopIndex = Int((fraction * Double(stops)).rounded())
		let snapped = effectiveBounds.lowerBound + stopIndex * DecadeRange.step
		apply(decade: snapped, isLower: isLower)
	}

	private func apply(decade: Int, isLower: Bool) {
		if isLower {
			range.lower = max(
				effectiveBounds.lowerBound,
				min(range.upper - DecadeRange.step, decade)
			)
		} else {
			range.upper = max(
				range.lower + DecadeRange.step,
				min(effectiveBounds.upperBound, decade)
			)
		}
	}

	private func adjust(isLower: Bool, increment: Bool) {
		let delta = increment ? DecadeRange.step : -DecadeRange.step
		let current = isLower ? clampedRange.lower : clampedRange.upper
		apply(decade: current + delta, isLower: isLower)
	}

	private func formatDecade(_ year: Int) -> String {
		"\(year)s"
	}
}

#Preview {
	@Previewable @State var range = DecadeRange(lower: 1970, upper: 2000)
	return Form {
		Section("Decade range") {
			DecadeRangeSlider(range: $range, bounds: 1960 ... 2020)
		}
	}
	.formStyle(.grouped)
}
