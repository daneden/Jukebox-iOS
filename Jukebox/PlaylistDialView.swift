//
//  PlaylistDialView.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import MusicKit
import SwiftUI
import UIKit

// MARK: - Tunables

//
// All visual knobs for the dial live here. Adjust freely.

enum DialTunables {
	/// Layout ------------------------------------------------------------
	/// Degrees of visual rotation per cover transition. Decoupled from
	/// item count — neighbors always sit at this angular spacing.
	static let stepVisual: Double = 20.0
	/// Cover diameter as a fraction of the dial container's smallest
	/// dimension (`min(width, height)`). Equivalent to a square
	/// containerRelativeFrame at this fraction — no hard pt cap, so the
	/// dial scales naturally to any device.
	static let coverSizeRatio: Double = 0.8
	/// Cylinder radius expressed as a multiple of `coverSize`. Larger =
	/// neighbors sit further out toward the screen edges. With an 0.8
	/// cover ratio the radius is reduced so prev/next still peek from
	/// the edges without flying off-screen.
	static let cylinderRadiusFactor: Double = 3.25
	/// Neighbors kept alive on each side of the focused cover. Wider than
	/// the visible arc on purpose, so artwork for adjacent covers is
	/// already loaded by the time they rotate into view.
	static let visibleHalf: Int = 3

	/// Scale -------------------------------------------------------------
	/// Scale at the absolute center of the dial.
	static let focusedScale: Double = 1
	/// Scale of covers at the back of the cylinder (covers off-screen).
	static let edgeScale: Double = 0.30
	/// Sharpness of the scale falloff away from center.
	/// 1 = linear; >1 = focused stays bigger longer.
	static let scaleCurveExponent: Double = 1.5

	/// 3D feel -----------------------------------------------------------
	/// Per-cover 3D tilt multiplier. 1 = full tilt (very Cover-Flow),
	/// 0 = no tilt (covers stay flat). Layout offset is unaffected.
	static let rotationDamping: Double = 0.55
	/// `perspective` argument passed to rotation3DEffect.
	static let perspective: Double = 0.6
	/// Continuous wobble amplitude on the focused cover, in degrees.
	static let wobbleAmplitude: Double = 1.5
	/// Wobble period in seconds.
	static let wobblePeriod: Double = 8.0

	/// Memory ------------------------------------------------------------
	/// Multiplier on the peak displayed cover size (`coverSize × focusedScale`)
	/// used when requesting artwork from MusicKit. 1.0 = pixel-exact at peak
	/// zoom (sharp); 0.5 = ¼ the memory per cover but ~2× upsample blur.
	static let artworkRequestRatio: Double = 1.0

	/// Shuffle -----------------------------------------------------------
	/// Maximum number of items the shuffle button is allowed to jump
	/// over in a single spin. Keeps random picks within a bounded
	/// neighborhood so the wheel doesn't have to traverse half the deck
	/// (and load all those covers) on every press.
	static let maxShuffleJump: Int = 24

	/// Motion ------------------------------------------------------------
	/// SwiftUI spring used for every animated wheel transition — drag-snap,
	/// tap-to-focus, shuffle, and the focused cover's shadow/blur crossfade.
	/// Tune `bounce` for more/less overshoot; `duration` is SwiftUI's
	/// perceptual settle time.
	static let wheelSpring: Animation = .spring(duration: 0.6, bounce: 0.28)
	/// Exponent on the superlinear flick-inertia term. The settle projection
	/// is `raw + raw^exponent × boost` (in detents): the `raw` term keeps
	/// slow flicks at native scroll feel, while the `raw^exponent × boost`
	/// term amplifies fast flicks. Higher exponent = steeper "fast flicks go
	/// way further" behavior. 1.0 reduces this to a linear `(1 + boost)×`
	/// scaling — useless; keep above 1.5.
	static let flickInertiaExponent: Double = 2.0
	/// Scale on the superlinear flick-inertia term. 0.0 = pure native scroll;
	/// higher = stronger fast-flick boost. Tune with ``flickInertiaExponent``.
	static let flickInertiaBoost: Double = 0.3
}

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

	/// Re-exported so other files (e.g. the reanchor logic in each mode) can
	/// convert between rotation and continuous position without reaching
	/// into the tunables enum.
	static var stepVisual: Double {
		DialTunables.stepVisual
	}

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
				// SwiftUI-native spring: interrupts cleanly when a new gesture
				// or another withAnimation lands, and the bounce settles
				// smoothly to exact target (no manual end-clamp snap).
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
		let newRot = Self.spinDestination(current: rotation, target: index, count: count)
		withAnimation(DialTunables.wheelSpring) {
			rotation = newRot
		}
	}

	/// Rotation that lands `target` at the front via the **shortest modular path**.
	/// No forced full-rotations, no minimum sweep — the wheel just travels
	/// straight to its destination, which keeps the number of covers that
	/// pass through the visible window (and therefore image loads) bounded.
	static func spinDestination(
		current: Angle,
		target: Int,
		count: Int
	) -> Angle {
		guard count > 0 else { return current }
		let cp = -current.degrees / DialTunables.stepVisual
		var diff = (Double(target) - cp).truncatingRemainder(dividingBy: Double(count))
		let half = Double(count) / 2
		if diff > half { diff -= Double(count) }
		if diff < -half { diff += Double(count) }
		let newCp = cp + diff
		return .degrees(-newCp * DialTunables.stepVisual)
	}
}

// MARK: - Animatable content

/// Renders the visible window of covers. Conforms to `Animatable` with rotation
/// as `animatableData` so SwiftUI's animation system re-runs `body` once per
/// frame during any `withAnimation` transition — that's what lets covers
/// actually fly past during a long-distance snap instead of cross-fading at
/// the destination. The setter is also the per-detent haptic site for
/// animation-driven motion (drag haptics still flow through the parent's
/// `.sensoryFeedback(trigger: focusedIndex)`, which fires on real-time
/// gesture-driven state updates that don't go through Animatable).
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
		// reported in. Means the touch point can be passed straight through
		// as the ripple origin without un-projecting the 3D transforms.
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
