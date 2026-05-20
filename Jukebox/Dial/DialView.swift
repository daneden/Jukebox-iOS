//
//  DialView.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import MusicKit
import SwiftUI
import UIKit

// MARK: - Haptics

/// Persistent selection-feedback generator. Holding it across renders keeps it
/// prepared between detent crossings (vs spinning up a fresh generator each
/// time, which can drop the first tick).
private enum DialHapticEngine {
	static let selection: UISelectionFeedbackGenerator = {
		let g = UISelectionFeedbackGenerator()
		g.prepare()
		return g
	}()
}

// MARK: - Dial

/// Generic over any `MusicItem` that conforms to `DialItem` (i.e. has artwork).
/// Both Playlists and Songs ride the same component — one set of physics,
/// haptics, and bounded-rendering rules.
struct DialView<Item: MusicItem & DialItem>: View {
	let items: MusicItemCollection<Item>
	@Binding var rotation: Angle
	@Binding var focusedIndex: Int
	/// Per-item ripple trigger counter. Each cover reads its own entry as
	/// the RippleEffect trigger, so a shuffle landing on item X bumps only
	/// X's counter and only X ripples.
	var rippleCounters: [MusicItemID: Int] = [:]
	var placeholderSymbol: String = "music.note.list"
	var onTapFocused: () -> Void = {}

	@State private var dragStartRotation: Angle?

	private var continuousPosition: Double {
		guard !items.isEmpty else { return 0 }
		return -rotation.degrees / DialTunables.stepVisual
	}

	var body: some View {
		GeometryReader { proxy in
			// 80% of the smaller container dimension. Equivalent to applying
			// `containerRelativeFrame([.horizontal, .vertical]) { l, _ in l * 0.8 }`
			// and constraining to a square — but expressed inline because the
			// closure-based API can't compute min-of-both directly.
			let coverSize = min(proxy.size.width, proxy.size.height) * DialTunables.coverSizeRatio
			// Request at the peak displayed size so the focused cover (which can
			// be scaled up by focusedScale) renders without upsample blur.
			let requestSize = coverSize * DialTunables.focusedScale * DialTunables.artworkRequestRatio
			let radius = coverSize * DialTunables.cylinderRadiusFactor

			DialContent(
				rotation: rotation.degrees,
				items: items,
				coverSize: coverSize,
				requestSize: requestSize,
				radius: radius,
				rippleCounters: rippleCounters,
				placeholderSymbol: placeholderSymbol,
				onTap: handleTap
			)
			.frame(width: proxy.size.width, height: proxy.size.height)
			.contentShape(.rect)
			.simultaneousGesture(dragGesture(coverWidth: coverSize))
		}
		.onChange(of: rotation) { _, _ in updateFocus() }
	}

	private func dragGesture(coverWidth: Double) -> some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { value in
				if dragStartRotation == nil { dragStartRotation = rotation }
				let perPoint = DialTunables.stepVisual / coverWidth
				rotation = (dragStartRotation ?? .zero) + .degrees(value.translation.width * perPoint)
			}
			.onEnded { value in
				dragStartRotation = nil
				// Normalize the flick projection into detent units (1 detent
				// = coverWidth points of finger travel — same conversion the
				// active drag uses). Then apply a superlinear curve so slow
				// flicks stay at native scroll feel while fast ones traverse
				// exponentially further.
				let rawDetents = (value.predictedEndTranslation.width - value.translation.width) / coverWidth
				let sign: Double = rawDetents < 0 ? -1 : 1
				let absDetents = abs(rawDetents)
				let boostedDetents = absDetents + pow(absDetents, DialTunables.flickInertiaExponent) * DialTunables.flickInertiaBoost
				let projected = rotation.degrees + sign * boostedDetents * DialTunables.stepVisual
				let projectedPos = -projected / DialTunables.stepVisual
				let snappedPos = projectedPos.rounded()
				let snappedRot = -snappedPos * DialTunables.stepVisual
				withAnimation(DialTunables.wheelSpring) {
					rotation = .degrees(snappedRot)
				}
			}
	}

	private func updateFocus() {
		let count = items.count
		guard count > 0 else { return }
		let idx = ((Int(continuousPosition.rounded()) % count) + count) % count
		if idx != focusedIndex {
			focusedIndex = idx
		}
	}

	private func handleTap(on index: Int) {
		if index == focusedIndex {
			onTapFocused()
			return
		}
		let count = items.count
		guard count > 0 else { return }
		let newRot = DialMechanics.spinDestination(current: rotation, target: index, count: count)
		withAnimation(DialTunables.wheelSpring) {
			rotation = newRot
		}
	}
}

// MARK: - Animatable content

/// Renders the visible window of covers. Conforms to `Animatable` with rotation
/// as `animatableData` so SwiftUI's animation system re-runs `body` once per
/// frame during any `withAnimation` transition — that's what lets covers
/// actually fly past during a long-distance snap instead of cross-fading at
/// the destination. The setter is also the per-detent haptic site for
/// animation-driven motion (drag haptics still flow through the parent's
/// `.sensoryFeedback(trigger: focusedIndex)`).
private struct DialContent<Item: MusicItem & DialItem>: View, Animatable {
	var rotation: Double
	let items: MusicItemCollection<Item>
	let coverSize: Double
	let requestSize: Double
	let radius: Double
	let rippleCounters: [MusicItemID: Int]
	let placeholderSymbol: String
	let onTap: (Int) -> Void

	var animatableData: Double {
		get { rotation }
		set {
			let previousDetent = Int((-rotation / DialTunables.stepVisual).rounded())
			rotation = newValue
			let newDetent = Int((-newValue / DialTunables.stepVisual).rounded())
			if previousDetent != newDetent {
				DialHapticEngine.selection.selectionChanged()
			}
		}
	}

	private var continuousPosition: Double {
		guard !items.isEmpty else { return 0 }
		return -rotation / DialTunables.stepVisual
	}

	var body: some View {
		ZStack {
			ForEach(visibleEntries(), id: \.id) { entry in
				DialItemView(
					artwork: entry.item.artwork,
					coverSize: coverSize,
					requestSize: requestSize,
					radius: radius,
					screenAngle: entry.screenAngle,
					isFocused: entry.isFocused,
					rippleTrigger: entry.rippleTrigger,
					placeholderSymbol: placeholderSymbol
				) {
					onTap(entry.index)
				}
			}
		}
	}

	private struct DialEntry: Identifiable {
		let id: MusicItemID
		let index: Int
		let item: Item
		let screenAngle: Angle
		let isFocused: Bool
		let rippleTrigger: Int
	}

	private func visibleEntries() -> [DialEntry] {
		let count = items.count
		guard count > 0 else { return [] }
		let cp = continuousPosition
		let cpRounded = cp.rounded()
		let focused = ((Int(cpRounded) % count) + count) % count
		let fractional = cp - cpRounded

		var seen = Set<Int>()
		var entries: [DialEntry] = []
		for k in -DialTunables.visibleHalf ... DialTunables.visibleHalf {
			let idx = ((focused + k) % count + count) % count
			guard seen.insert(idx).inserted else { continue }
			let offset = Double(k) - fractional
			let itemID = items[idx].id
			entries.append(DialEntry(
				id: itemID,
				index: idx,
				item: items[idx],
				screenAngle: .degrees(offset * DialTunables.stepVisual),
				isFocused: idx == focused,
				rippleTrigger: rippleCounters[itemID] ?? 0
			))
		}
		return entries
	}
}

// MARK: - Single dial item

private struct DialItemView: View {
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

	var body: some View {
		let radians = screenAngle.radians
		let depth = cos(radians)
		let normalized = max(0, depth)
		let xOffset = sin(radians) * radius
		let scale = DialTunables.edgeScale
			+ (DialTunables.focusedScale - DialTunables.edgeScale)
			* pow(normalized, DialTunables.scaleCurveExponent)
		let opacity = normalized
		let blur = (1 - normalized) * 3

		TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isFocused)) { context in
			wobblingCover(at: context.date)
		}
		.rotation3DEffect(
			.degrees(screenAngle.degrees * DialTunables.rotationDamping),
			axis: (x: 0, y: 1, z: 0),
			perspective: DialTunables.perspective
		)
		.offset(x: xOffset)
		.scaleEffect(scale)
		.opacity(opacity)
		.blur(radius: blur)
		.zIndex(normalized)
		.animation(DialTunables.wheelSpring, value: isFocused)
		.onChange(of: rippleTrigger) { _, _ in
			rippleOrigin = CGPoint(x: coverSize / 2, y: coverSize * 0.9)
			rippleTriggerCount &+= 1
		}
	}

	@ViewBuilder
	private func wobblingCover(at date: Date) -> some View {
		let t = date.timeIntervalSinceReferenceDate
		let omega: Double = 2 * .pi / DialTunables.wobblePeriod
		let wobbleX: Double = isFocused ? sin(t * omega) * DialTunables.wobbleAmplitude : 0
		let wobbleY: Double = isFocused ? cos(t * omega) * DialTunables.wobbleAmplitude : 0

		// Plain onTapGesture instead of Button — Button's gesture eats the
		// parent's DragGesture until a hard flick breaks it loose, which
		// makes the wheel feel stuck. A tap gesture composes cleanly with
		// the simultaneousGesture drag on the parent ZStack.
		//
		// RippleEffect is attached BEFORE rotation3DEffect/shadow so the
		// shader's local coordinate space is the cover's own
		// (coverSize × coverSize) frame — same space the tap location is
		// reported in.
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
		.onTapGesture(coordinateSpace: .local) { location in
			if isFocused {
				rippleOrigin = location
				rippleTriggerCount &+= 1
			}
			onTap()
		}
		.shadow(color: .black.opacity(0.35), radius: isFocused ? 28 : 10, y: isFocused ? 16 : 6)
		.rotation3DEffect(.degrees(wobbleX), axis: (x: 1, y: 0, z: 0))
		.rotation3DEffect(.degrees(wobbleY), axis: (x: 0, y: 1, z: 0))
	}
}
