//
//  DecadeRangeSlider.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Two-thumb range slider for a decade interval. SwiftUI's native
//  Slider is single-value through iOS 26, so the dual-thumb behaviour
//  is hand-rolled: ZStack thumbs at calculated offsets, drag gestures
//  in a named coordinate space so the touch math survives the offsets.
//

import SwiftUI

struct DecadeRangeSlider: View {
	@Binding var range: DecadeRange
	/// Effective bounds for the thumbs; nil falls back to 1900–2030.
	/// Caller usually derives these from the user's actual library.
	var bounds: ClosedRange<Int>?

	// Capsule thumb, 2× wider than tall — distinct from the round
	// Play/Shuffle buttons while still reading as a draggable handle.
	private static let thumbWidth: CGFloat = 36
	private static let thumbHeight: CGFloat = 24
	private static let trackHeight: CGFloat = 6
	private static let tickSize: CGFloat = 3
	/// Track centre → tick row, so the dots sit just below the track.
	private static let tickGapBelowTrack: CGFloat = 6
	private static let coordinateSpaceName = "DecadeRangeSliderTrack"

	// Per-thumb active flag driving the white fill's opacity (glass
	// shows through while touched). `@GestureState` auto-resets on
	// gesture end/cancel — more reliable than tracking with @State.
	@GestureState private var lowerActive = false
	@GestureState private var upperActive = false
	/// Distance (pts) each thumb has dragged past its outer bound.
	/// Auto-resets on gesture end; with the spring `.animation` on the
	/// rubber-band scale that gives a clean snap-back to identity.
	@GestureState private var lowerOverdrag: CGFloat = 0
	@GestureState private var upperOverdrag: CGFloat = 0
	/// Last-touched thumb, driving a zIndex swap so it stays on top
	/// when the two overlap — otherwise dragging the lower onto the
	/// upper buries it under the upper's hit region, unrecoverable.
	@State private var frontmostThumb: ThumbKind = .upper

	private enum ThumbKind { case lower, upper }

	/// Visible-stretch cap; the rubber-band asymptotes here.
	private static let maxStretchPts: CGFloat = 40
	/// Fixed baseline (not the actual slider width) for converting
	/// damped stretch into a scaleEffect factor, so the stretch reads
	/// consistently regardless of frame. Higher = stiffer band.
	private static let stretchReferenceWidth: CGFloat = 320
	/// Minimum track height as the band is pulled thin.
	private static let minTrackHeight: CGFloat = 2

	private var effectiveBounds: ClosedRange<Int> {
		bounds ?? (DecadeRange.minDecade ... DecadeRange.maxDecade)
	}

	private var spanDecades: Int {
		effectiveBounds.upperBound - effectiveBounds.lowerBound
	}

	/// Every decade detent in the effective bounds, inclusive.
	private var decadeStops: [Int] {
		Array(stride(
			from: effectiveBounds.lowerBound,
			through: effectiveBounds.upperBound,
			by: DecadeRange.step
		))
	}

	/// Range clamped into the effective bounds so a saved value from a
	/// broader prior library window doesn't push the thumb off-track.
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
		HStack(spacing: -10) {
			Text(formatDecade(clampedRange.lower))
				// Decorative — same values are on the container and each
				// thumb, so announcing here would triple the read-out.
				.accessibilityHidden(true)

			GeometryReader { geo in
				track(in: geo.size.width)
			}
			.frame(height: Self.thumbHeight)
			.coordinateSpace(name: Self.coordinateSpaceName)
			// Rubber-band stretch when a thumb is dragged past its
			// bound, scoped to the track so the flanking labels stay
			// put. Two scaleEffects: lower-overdrag pulls leftward
			// (trailing anchor), upper rightward (leading anchor).
			.scaleEffect(
				x: 1 + rubberBand(lowerOverdrag) / Self.stretchReferenceWidth,
				anchor: .trailing
			)
			.scaleEffect(
				x: 1 + rubberBand(upperOverdrag) / Self.stretchReferenceWidth,
				anchor: .leading
			)
			.animation(.spring(response: 0.35, dampingFraction: 0.65), value: lowerOverdrag)
			.animation(.spring(response: 0.35, dampingFraction: 0.65), value: upperOverdrag)

			Text(formatDecade(clampedRange.upper))
				.accessibilityHidden(true)
		}
		.font(.callout.monospacedDigit().weight(.medium))
		.foregroundStyle(isAtBounds ? .secondary : .primary)
		// `.contain` makes the control a labelled container that still
		// exposes each thumb as an independently focusable adjustable
		// element: VoiceOver lands on the container, hears the range,
		// then navigates into either thumb to adjust.
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Decade range")
		.accessibilityValue(accessibilityRangeValue)
		.sensoryFeedback(.selection, trigger: clampedRange.lower)
		.sensoryFeedback(.selection, trigger: clampedRange.upper)
	}

	/// iOS-style asymptotic damping: near-1:1 for small overdrag,
	/// then resists, never exceeding `maxStretchPts`.
	private func rubberBand(_ overdrag: CGFloat) -> CGFloat {
		guard overdrag > 0 else { return 0 }
		return Self.maxStretchPts * (1 - 1 / (overdrag / Self.maxStretchPts + 1))
	}

	/// Track height shrinks as the band is pulled — same
	/// damped-overdrag drive as the stretch, so thinning and widening
	/// stay coupled. At rest = trackHeight; full stretch = minTrackHeight.
	private var dynamicTrackHeight: CGFloat {
		let damped = rubberBand(lowerOverdrag) + rubberBand(upperOverdrag)
		let shrinkFactor = min(1, damped / Self.maxStretchPts)
		return Self.trackHeight - (Self.trackHeight - Self.minTrackHeight) * shrinkFactor
	}

	private var accessibilityRangeValue: String {
		"\(formatDecade(clampedRange.lower)) to \(formatDecade(clampedRange.upper))"
	}

	private func track(in width: CGFloat) -> some View {
		// `usable` is the thumb leading-edge travel. Thumbs edge-align
		// with the track at the extremes, and track edges live
		// `thumbWidth/2` inside the container (Capsule padding), so
		// travel is `width - 2 × thumbWidth` and the offset starts at
		// `thumbWidth/2`.
		let usable = max(0, width - 2 * Self.thumbWidth)
		let lowerX = Self.thumbWidth / 2 + position(for: clampedRange.lower, usable: usable)
		let upperX = Self.thumbWidth / 2 + position(for: clampedRange.upper, usable: usable)

		return ZStack(alignment: .leading) {
			// Decade ticks, below the track in z-order and position so
			// they read as a ruler. Tick centre = thumb centre at that
			// decade (`thumbWidth + position`), under where a snapped
			// thumb would sit.
			ForEach(decadeStops, id: \.self) { decade in
				Circle()
					.fill(.tertiary)
					.frame(width: Self.tickSize, height: Self.tickSize)
					.offset(
						x: Self.thumbWidth + position(for: decade, usable: usable) - Self.tickSize / 2,
						y: Self.trackHeight / 2 + Self.tickGapBelowTrack
					)
			}

			Capsule()
				.fill(.quinary)
				.frame(height: dynamicTrackHeight)
				.padding(.horizontal, Self.thumbWidth / 2)

			// Fill spans thumb-centre → thumb-centre, but extends to a
			// thumb's outer edge when it's parked at its bound, so a
			// full-range selection fills the whole track.
			let lowerAtBound = clampedRange.lower <= effectiveBounds.lowerBound
			let upperAtBound = clampedRange.upper >= effectiveBounds.upperBound
			let fillLeading = lowerAtBound ? lowerX : lowerX + Self.thumbWidth / 2
			let fillTrailing = upperAtBound ? upperX + Self.thumbWidth : upperX + Self.thumbWidth / 2
			Capsule()
				.fill(.tint)
				.frame(width: max(0, fillTrailing - fillLeading), height: dynamicTrackHeight)
				.offset(x: fillLeading)

			GlassEffectContainer {
				ZStack(alignment: .leading) {
					thumbView(
						isLower: true,
						active: $lowerActive,
						overdrag: $lowerOverdrag,
						xOffset: lowerX,
						usable: usable
					)
					.zIndex(frontmostThumb == .lower ? 1 : 0)
					thumbView(
						isLower: false,
						active: $upperActive,
						overdrag: $upperOverdrag,
						xOffset: upperX,
						usable: usable
					)
					.zIndex(frontmostThumb == .upper ? 1 : 0)
				}
			}
		}
		.animation(.snappy, value: lowerX)
		.animation(.snappy, value: upperX)
	}

	/// One thumb, parameterised by which end of the range it is.
	/// `isLower` switches the overdrag sign: the lower thumb overshoots
	/// past the leading edge, the upper past the trailing edge.
	private func thumbView(
		isLower: Bool,
		active: GestureState<Bool>,
		overdrag: GestureState<CGFloat>,
		xOffset: CGFloat,
		usable: CGFloat
	) -> some View {
		thumb(active: active.wrappedValue)
			.offset(x: xOffset)
			.gesture(
				DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
					.updating(active) { _, state, _ in state = true }
					.updating(overdrag) { value, state, _ in
						let touchX = value.location.x - Self.thumbWidth
						state = max(0, isLower ? -touchX : touchX - usable)
					}
					.onChanged { value in
						let kind: ThumbKind = isLower ? .lower : .upper
						if frontmostThumb != kind { frontmostThumb = kind }
						handleDrag(value: value, usable: usable, isLower: isLower)
					}
			)
			.accessibilityElement()
			.accessibilityLabel(isLower ? "Earliest decade" : "Latest decade")
			.accessibilityValue(formatDecade(isLower ? clampedRange.lower : clampedRange.upper))
			.accessibilityAdjustableAction { direction in
				adjust(isLower: isLower, increment: direction == .increment)
			}
			// ZStack with absolute offsets gives SwiftUI no reliable
			// reading order, so set it explicitly: lower before upper.
			.accessibilitySortPriority(isLower ? 2 : 1)
	}

	private func thumb(active: Bool) -> some View {
		// White fill drops to 0% on active so the glass reads clean
		// during the drag. `scaleEffect` (not a frame change) grows the
		// thumb on press without re-laying-out, so the placing `.offset`
		// stays anchored to its centre.
		ZStack {
			Capsule()
				.fill(.white)
				.opacity(active ? 0 : 1)

			if active {
				Capsule()
					.fill(.clear)
					.glassEffect(.clear.tint(.primary.opacity(0.0125)).interactive(), in: .capsule)
			}
		}
		.shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
		.frame(width: Self.thumbWidth, height: Self.thumbHeight)
		.scaleEffect(active ? 1.5 : 1)
		.animation(active ? .interactiveSpring(duration: 0.18, extraBounce: 0.15).delay(0.2) : .smooth(duration: 0.2), value: active)
	}

	private func position(for decade: Int, usable: CGFloat) -> CGFloat {
		guard spanDecades > 0 else { return 0 }
		let fraction = Double(decade - effectiveBounds.lowerBound) / Double(spanDecades)
		return CGFloat(fraction) * usable
	}

	/// Named coordinate space is anchored on the GeometryReader, so
	/// `location.x` is in the track's frame regardless of which thumb
	/// is firing.
	private func handleDrag(value: DragGesture.Value, usable: CGFloat, isLower: Bool) {
		// Thumb centre follows the finger; subtract a full thumbWidth to
		// map into the [0, usable] space (itself offset thumbWidth/2 so
		// the thumb edge-aligns with the track at the extremes).
		let touchX = value.location.x - Self.thumbWidth
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

/// Real View instead of inline `@Previewable @State`: two @Previewables
/// in one #Preview body reliably crash the preview agent on this Xcode
/// toolchain (SIGSEGV at module init). Owning state here sidesteps the macro.
private struct DecadeRangeSliderPreviewHost: View {
	@State private var range = DecadeRange(lower: 1970, upper: 2000)
	@State private var nativeValue: Double = 1980

	var body: some View {
		Form {
			Section("Custom range slider") {
				DecadeRangeSlider(range: $range, bounds: 1960 ... 2020)
			}
			Section("Native SwiftUI Slider (reference)") {
				// Same range and step as the custom slider above, to
				// A/B the rendering until the two read as siblings.
				Slider(
					value: $nativeValue,
					in: 1960 ... 2020,
					step: 10
				) {
					Text("Year")
				} minimumValueLabel: {
					Text("1960s")
						.font(.callout.monospacedDigit().weight(.medium))
				} maximumValueLabel: {
					Text("2020s")
						.font(.callout.monospacedDigit().weight(.medium))
				}
			}
		}
		.formStyle(.grouped)
	}
}

#Preview {
	DecadeRangeSliderPreviewHost()
}
