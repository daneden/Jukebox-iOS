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

	private static let thumbSize: CGFloat = 28
	private static let trackHeight: CGFloat = 4
	private static let coordinateSpaceName = "DecadeRangeSliderTrack"

	private var spanDecades: Int {
		DecadeRange.maxDecade - DecadeRange.minDecade
	}

	var body: some View {
		VStack(spacing: 6) {
			HStack {
				Text(formatDecade(range.lower))
				Spacer()
				Text(formatDecade(range.upper))
			}
			.font(.callout.monospacedDigit().weight(.medium))
			.foregroundStyle(range.isUnbounded ? .secondary : .primary)

			GeometryReader { geo in
				track(in: geo.size.width)
			}
			.frame(height: Self.thumbSize)
			.coordinateSpace(name: Self.coordinateSpaceName)
		}
	}

	private func track(in width: CGFloat) -> some View {
		let usable = max(0, width - Self.thumbSize)
		let lowerX = position(for: range.lower, usable: usable)
		let upperX = position(for: range.upper, usable: usable)

		return ZStack(alignment: .leading) {
			Capsule()
				.fill(.tertiary)
				.frame(height: Self.trackHeight)
				.padding(.horizontal, Self.thumbSize / 2)

			Capsule()
				.fill(.tint)
				.frame(width: max(0, upperX - lowerX), height: Self.trackHeight)
				.offset(x: lowerX + Self.thumbSize / 2)

			thumb()
				.offset(x: lowerX)
				.gesture(dragGesture(usable: usable, isLower: true))
				.accessibilityElement()
				.accessibilityLabel("Decade range start")
				.accessibilityValue(formatDecade(range.lower))
				.accessibilityAdjustableAction { direction in
					adjust(isLower: true, increment: direction == .increment)
				}

			thumb()
				.offset(x: upperX)
				.gesture(dragGesture(usable: usable, isLower: false))
				.accessibilityElement()
				.accessibilityLabel("Decade range end")
				.accessibilityValue(formatDecade(range.upper))
				.accessibilityAdjustableAction { direction in
					adjust(isLower: false, increment: direction == .increment)
				}
		}
	}

	private func thumb() -> some View {
		Circle()
			.fill(.background)
			.shadow(color: .black.opacity(0.2), radius: 2, y: 1)
			.overlay(Circle().strokeBorder(.tint.opacity(0.6), lineWidth: 1))
			.frame(width: Self.thumbSize, height: Self.thumbSize)
	}

	private func position(for decade: Int, usable: CGFloat) -> CGFloat {
		guard spanDecades > 0 else { return 0 }
		let fraction = Double(decade - DecadeRange.minDecade) / Double(spanDecades)
		return CGFloat(fraction) * usable
	}

	private func dragGesture(usable: CGFloat, isLower: Bool) -> some Gesture {
		// `minimumDistance: 0` so a touch-down on the thumb starts
		// tracking immediately. Named coordinate space is anchored on
		// the GeometryReader, so `location.x` is in the track's frame
		// regardless of which thumb's gesture is firing.
		DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
			.onChanged { value in
				let touchX = value.location.x - Self.thumbSize / 2
				let clampedX = max(0, min(usable, touchX))
				let fraction = usable > 0 ? Double(clampedX / usable) : 0
				let stops = spanDecades / DecadeRange.step
				let stopIndex = Int((fraction * Double(stops)).rounded())
				let snapped = DecadeRange.minDecade + stopIndex * DecadeRange.step
				apply(decade: snapped, isLower: isLower)
			}
	}

	private func apply(decade: Int, isLower: Bool) {
		if isLower {
			range.lower = max(
				DecadeRange.minDecade,
				min(range.upper - DecadeRange.step, decade)
			)
		} else {
			range.upper = max(
				range.lower + DecadeRange.step,
				min(DecadeRange.maxDecade, decade)
			)
		}
	}

	private func adjust(isLower: Bool, increment: Bool) {
		let delta = increment ? DecadeRange.step : -DecadeRange.step
		let current = isLower ? range.lower : range.upper
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
			DecadeRangeSlider(range: $range)
		}
	}
	.formStyle(.grouped)
}
