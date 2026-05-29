//
//  ScrollWheelInput.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  macOS trackpad / mouse-wheel input for the dial.

#if os(macOS)

	import AppKit
	import SwiftUI

	/// Forwards scroll events while the cursor is over the modified view to
	/// `onScroll`. Uses `NSEvent.addLocalMonitorForEvents` rather than an
	/// `NSViewRepresentable` overlay so it doesn't claim hit-testing — clicks
	/// still reach the SwiftUI views below. The hover flag is a class so the
	/// long-lived monitor closure reads the latest value without going stale.
	struct ScrollWheelDialReader: ViewModifier {
		let onScroll: (CGFloat, NSEvent.Phase) -> Void

		@State private var hoverFlag = HoverFlag()
		@State private var monitor = ScrollMonitor()

		func body(content: Content) -> some View {
			content
				.onContinuousHover { phase in
					switch phase {
					case .active: hoverFlag.isInside = true
					case .ended: hoverFlag.isInside = false
					}
				}
				.onAppear { monitor.start(flag: hoverFlag, onScroll: onScroll) }
				.onDisappear { monitor.stop() }
		}
	}

	private final class HoverFlag {
		var isInside: Bool = false
	}

	@MainActor
	private final class ScrollMonitor {
		private var monitor: Any?

		func start(flag: HoverFlag, onScroll: @escaping (CGFloat, NSEvent.Phase) -> Void) {
			stop()
			monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
				guard flag.isInside else { return event }
				let dx = event.scrollingDeltaX
				let dy = event.scrollingDeltaY
				// Dominant axis; negate dy so scroll-down advances focus.
				let delta: CGFloat = abs(dx) >= abs(dy) ? dx : -dy
				onScroll(delta, event.phase)
				return nil
			}
		}

		func stop() {
			if let monitor {
				NSEvent.removeMonitor(monitor)
				self.monitor = nil
			}
		}

		deinit {
			if let monitor {
				NSEvent.removeMonitor(monitor)
			}
		}
	}

#endif
