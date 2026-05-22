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
	private static let thumbWidth: CGFloat = 36
	private static let thumbHeight: CGFloat = 24
	private static let trackHeight: CGFloat = 6
	private static let tickSize: CGFloat = 3
	/// Distance from track centre to the tick row, so the dots sit
	/// just below the track edge without overlapping it.
	private static let tickGapBelowTrack: CGFloat = 6
	private static let coordinateSpaceName = "DecadeRangeSliderTrack"

	// Per-thumb interaction state — drives the inner white fill's
	// opacity so the glass underneath shows through while the thumb
	// is being touched. `@GestureState` auto-resets when the gesture
	// ends or is cancelled (more reliable than tracking with @State).
	@GestureState private var lowerActive = false
	@GestureState private var upperActive = false
	/// Raw distance (pts) the user has dragged each thumb past its
	/// outer bound — lower past min, upper past max. Auto-resets on
	/// gesture end, which combined with the spring `.animation` on
	/// the rubber-band scale gives a clean snap-back to identity.
	@GestureState private var lowerOverdrag: CGFloat = 0
	@GestureState private var upperOverdrag: CGFloat = 0

	/// Cap on visible stretch. The rubber-band function asymptotes
	/// to this value no matter how far the finger pulls.
	private static let maxStretchPts: CGFloat = 40
	/// Reference width used to convert the damped stretch (in pts)
	/// into a scaleEffect factor. Not the actual slider width — a
	/// fixed baseline so the horizontal stretch reads consistently
	/// regardless of the popover/sheet's actual frame. Higher value
	/// = stiffer-feeling band (less scaleX per pt of overdrag).
	private static let stretchReferenceWidth: CGFloat = 320
	/// Minimum visible track height as it gets pulled thin. The
	/// rubber-band metaphor — the band thins as it stretches.
	private static let minTrackHeight: CGFloat = 2

	private var effectiveBounds: ClosedRange<Int> {
		bounds ?? (DecadeRange.minDecade ... DecadeRange.maxDecade)
	}

	private var spanDecades: Int {
		effectiveBounds.upperBound - effectiveBounds.lowerBound
	}

	/// Every decade detent in the effective bounds, inclusive on
	/// both ends. The boundary ticks land directly under the resting
	/// positions of the thumbs at min/max.
	private var decadeStops: [Int] {
		Array(stride(
			from: effectiveBounds.lowerBound,
			through: effectiveBounds.upperBound,
			by: DecadeRange.step
		))
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
		HStack(spacing: -10) {
			Text(formatDecade(clampedRange.lower))
				// Visible labels are decorative — the same values are
				// surfaced via the container's accessibilityValue and
				// each thumb's accessibilityValue, so announcing them
				// here too would just triple the read-out.
				.accessibilityHidden(true)

			GeometryReader { geo in
				track(in: geo.size.width)
			}
			.frame(height: Self.thumbHeight)
			.coordinateSpace(name: Self.coordinateSpaceName)
			// Rubber-band stretch when a thumb is dragged past its
			// bound. Scoped to just the track/thumbs/ticks so the
			// flanking labels stay put — only the band itself
			// deforms. Two stacked scaleEffects: lower-overdrag pulls
			// the band leftward (anchored at trailing), upper-overdrag
			// pulls it rightward (anchored at leading). GestureState
			// resets to 0 on release; the spring animation runs the
			// snap-back automatically.
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
		// `.contain` makes the whole control a labelled accessibility
		// container that still exposes each thumb as an independently
		// focusable adjustable element underneath. VoiceOver users
		// land on the container first, hear a one-shot summary of the
		// current range, then navigate into either thumb to adjust.
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Decade range")
		.accessibilityValue(accessibilityRangeValue)
	}

	/// iOS-style asymptotic damping. Pulls at near-1:1 for small
	/// overdrag, then resists progressively, never exceeding
	/// `maxStretchPts` no matter how far the finger travels.
	private func rubberBand(_ overdrag: CGFloat) -> CGFloat {
		guard overdrag > 0 else { return 0 }
		return Self.maxStretchPts * (1 - 1 / (overdrag / Self.maxStretchPts + 1))
	}

	/// Track height that shrinks as the band is pulled — same
	/// damped-overdrag drive as the horizontal stretch, so the
	/// thinning and the widening are coupled. At rest = trackHeight;
	/// at full stretch = `minTrackHeight`.
	private var dynamicTrackHeight: CGFloat {
		let damped = rubberBand(lowerOverdrag) + rubberBand(upperOverdrag)
		let shrinkFactor = min(1, damped / Self.maxStretchPts)
		return Self.trackHeight - (Self.trackHeight - Self.minTrackHeight) * shrinkFactor
	}

	private var accessibilityRangeValue: String {
		"\(formatDecade(clampedRange.lower)) to \(formatDecade(clampedRange.upper))"
	}

	private func track(in width: CGFloat) -> some View {
		// `usable` is the span the thumb's leading-edge offset
		// travels. The thumbs edge-align with the track at the
		// extremes: at min, the lower thumb's leading edge sits
		// flush with the track's leading edge; at max, the upper
		// thumb's trailing edge sits flush with the track's
		// trailing edge. Track edges live `thumbWidth/2` inside the
		// container (the `.padding` on the track Capsule), so the
		// thumb's leading-edge travel is the track interior minus
		// another thumb width — `width - 2 × thumbWidth` — and the
		// offset starts at `thumbWidth/2` instead of 0.
		let usable = max(0, width - 2 * Self.thumbWidth)
		let lowerX = Self.thumbWidth / 2 + position(for: clampedRange.lower, usable: usable)
		let upperX = Self.thumbWidth / 2 + position(for: clampedRange.upper, usable: usable)

		return ZStack(alignment: .leading) {
			// Tick marks at every decade detent — small circles
			// rendered below the track in z-order *and* positioned
			// vertically below the track line, so they read as a
			// ruler underneath rather than competing with the track
			// or fill. Tick centre = thumb centre at that decade =
			// `thumbWidth + position`, so the tick lands directly
			// under where the thumb would sit if it snapped there.
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

			// Fill normally spans thumb-centre → thumb-centre. When a
			// thumb is parked at its bound, the fill extends out to
			// that thumb's *outer* edge instead — so a full-range
			// selection visually fills the entire track, and a
			// thumb-at-min reads as "everything from the very start"
			// rather than "from the middle of the thumb."
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
					thumbView(
						isLower: false,
						active: $upperActive,
						overdrag: $upperOverdrag,
						xOffset: upperX,
						usable: usable
					)
				}
			}
		}
		.animation(.snappy, value: lowerX)
		.animation(.snappy, value: upperX)
	}

	/// Constructs one thumb at the given offset, parameterised by
	/// which end of the range it represents. Both thumbs share
	/// identical gesture, accessibility, and styling shapes — only
	/// the active/overdrag GestureStates, the offset, the
	/// announcement strings, sort priority, and the overdrag
	/// direction differ. `isLower` switches the touch-overdrag sign:
	/// the lower thumb overshoots past the *leading* edge, the upper
	/// past the *trailing* edge.
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
					.onChanged { value in handleDrag(value: value, usable: usable, isLower: isLower) }
			)
			.accessibilityElement()
			.accessibilityLabel(isLower ? "Earliest decade" : "Latest decade")
			.accessibilityValue(formatDecade(isLower ? clampedRange.lower : clampedRange.upper))
			.accessibilityAdjustableAction { direction in
				adjust(isLower: isLower, increment: direction == .increment)
			}
			// Higher sort priority reads first. ZStack with absolute
			// offsets doesn't give SwiftUI a reliable layout order
			// to derive reading order from — make it explicit so
			// lower is always announced before upper.
			.accessibilitySortPriority(isLower ? 2 : 1)
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

	// `minimumDistance: 0` on the inline DragGesture so a touch-down
	// on the thumb starts tracking immediately. Named coordinate
	// space is anchored on the GeometryReader, so `location.x` is in
	// the track's frame regardless of which thumb's gesture is
	// firing.
	private func handleDrag(value: DragGesture.Value, usable: CGFloat, isLower: Bool) {
		// Thumb centre follows the finger, so its leading edge is
		// `touch.x - thumbWidth/2`. Subtract a further `thumbWidth/2`
		// to get the position into the new [0, usable] space — which
		// is offset by `thumbWidth/2` inside the container so the
		// thumb edge-aligns with the track edge at the extremes.
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

/// Preview wrapper as a real View instead of inline `@Previewable @State`
/// declarations — two @Previewables in one #Preview body have been
/// reliably crashing the preview agent on this Xcode toolchain (SIGSEGV
/// at module init, pointer-auth pattern in the report). Owning state
/// in a small host view sidesteps the macro entirely.
private struct DecadeRangeSliderPreviewHost: View {
	@State private var range = DecadeRange(lower: 1970, upper: 2000)
	@State private var nativeValue: Double = 1980

	var body: some View {
		Form {
			Section("Custom range slider") {
				DecadeRangeSlider(range: $range, bounds: 1960 ... 2020)
			}
			Section("Native SwiftUI Slider (reference)") {
				// Same numeric range and step so the track height,
				// thumb size, and tick spacing line up visually
				// with the custom slider above. Use this to A/B
				// the rendering and tune until the two read as
				// siblings.
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
