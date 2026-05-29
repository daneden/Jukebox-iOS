//
//  DialView.swift
//  Jukebox
//
//  Created by Daniel Eden on 19/05/2026.
//

import MusicKit
import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif
#if canImport(AppKit)
	import AppKit
#endif

// `DialItemView` (single rotating cover) lives in `DialItemView.swift`.
// `ScrollWheelDialReader` (macOS scroll input) lives in `ScrollWheelInput.swift`.

// MARK: - Haptics

// Persistent selection-feedback generator. Holding it across renders keeps it
// prepared between detent crossings (vs spinning up a fresh generator each
// time, which can drop the first tick). macOS has no equivalent direct
// generator suitable for firing inside `animatableData` (NSHapticFeedback
// requires a trackpad and isn't useful for keyboard/scroll-driven motion),
// so the per-frame detent tick is iOS-only — Mac falls back to the parent's
// `.sensoryFeedback(trigger: focusedIndex)` path, which still fires on
// every focus change, just not on intermediate animation frames.
#if canImport(UIKit)
	private enum DialHapticEngine {
		static let selection: UISelectionFeedbackGenerator = {
			let g = UISelectionFeedbackGenerator()
			g.prepare()
			return g
		}()
	}
#endif

// MARK: - Dial

/// Generic over any `MusicItem` that conforms to `DialItem` (i.e. has artwork).
/// Both Playlists and Songs ride the same component — one set of physics,
/// haptics, and bounded-rendering rules.
struct DialView<Item: MusicItem & DialItem, Menu: View>: View {
	let items: MusicItemCollection<Item>
	@Binding var rotation: Angle
	@Binding var focusedIndex: Int
	/// Per-item ripple trigger counter. Each cover reads its own entry as
	/// the RippleEffect trigger, so a shuffle landing on item X bumps only
	/// X's counter and only X ripples.
	var rippleCounters: [MusicItemID: Int] = [:]
	var placeholderSymbol: String = "music.note.list"
	/// Per-cover context menu, built by the mode (which holds the concrete
	/// `Song`/`Playlist` and so can offer item-specific actions). Declared
	/// before `onTapFocused` so the latter stays the trailing closure at
	/// call sites.
	@ViewBuilder var contextMenu: (Item) -> Menu
	var onTapFocused: () -> Void = {}

	@State private var dragStartRotation: Angle?
	#if os(macOS)
		@State private var scrollSnapTask: Task<Void, Never>?
	#endif

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
				contextMenu: contextMenu,
				onTap: handleTap
			)
			.frame(width: proxy.size.width, height: proxy.size.height)
			.contentShape(.rect)
			.simultaneousGesture(dragGesture(coverWidth: coverSize))
			#if os(macOS)
				.modifier(ScrollWheelDialReader { delta, phase in
					handleScroll(delta: delta, phase: phase, coverWidth: coverSize)
				})
			#endif
		}
		.onChange(of: rotation) { _, _ in updateFocus() }
	}

	#if os(macOS)
		private func handleScroll(delta: CGFloat, phase: NSEvent.Phase, coverWidth: Double) {
			let perPoint = DialTunables.stepVisual / coverWidth
			rotation = rotation + .degrees(delta * perPoint)

			scrollSnapTask?.cancel()

			if phase == .ended {
				snapToNearestDetent()
			} else if phase == [] {
				// Mouse wheel deliveries arrive without phase information,
				// so debounce a snap after the last tick instead of snapping
				// per event (which would spring-back every wheel notch).
				scrollSnapTask = Task { @MainActor in
					try? await Task.sleep(for: .milliseconds(140))
					guard !Task.isCancelled else { return }
					snapToNearestDetent()
				}
			}
		}

		private func snapToNearestDetent() {
			let projectedPos = -rotation.degrees / DialTunables.stepVisual
			let snappedPos = projectedPos.rounded()
			let snappedRot = -snappedPos * DialTunables.stepVisual
			withAnimation(DialTunables.wheelSpring) {
				rotation = .degrees(snappedRot)
			}
		}
	#endif

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
private struct DialContent<Item: MusicItem & DialItem, Menu: View>: View, Animatable {
	var rotation: Double
	let items: MusicItemCollection<Item>
	let coverSize: Double
	let requestSize: Double
	let radius: Double
	let rippleCounters: [MusicItemID: Int]
	let placeholderSymbol: String
	@ViewBuilder let contextMenu: (Item) -> Menu
	let onTap: (Int) -> Void

	var animatableData: Double {
		get { rotation }
		set {
			let previousDetent = Int((-rotation / DialTunables.stepVisual).rounded())
			rotation = newValue
			let newDetent = Int((-newValue / DialTunables.stepVisual).rounded())
			if previousDetent != newDetent {
				#if canImport(UIKit)
					DialHapticEngine.selection.selectionChanged()
				#endif
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
				// Custom static preview. The live cover wobbles (a TimelineView
				// driving rotation3DEffect) and carries 3D/scale/blur/shadow
				// transforms, so the default context-menu snapshot lifts a
				// skewed, mid-oscillation tile. A plain CoverArtView shows the
				// artwork flat and still. The preview variant is iOS-only —
				// AppKit context menus have no preview, so macOS uses the
				// menu-only form.
				#if os(iOS)
				.contextMenu {
					contextMenu(entry.item)
				} preview: {
					CoverArtView(
						artwork: entry.item.artwork,
						width: coverSize,
						requestedWidth: requestSize,
						placeholderSymbol: placeholderSymbol
					)
				}
				#else
				.contextMenu { contextMenu(entry.item) }
				#endif
				// Covers entering or leaving the visible window (because
				// the library reordered while we were backgrounded, the
				// deck was reshuffled, or focus jumped) blur-replace
				// rather than scale-fade. Pair with the .smooth curve
				// in the mode's applyPlaylists/applyDeck so the slide
				// of stayers and the blur of movers share the same
				// transaction.
				.transition(.blurReplace)
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
