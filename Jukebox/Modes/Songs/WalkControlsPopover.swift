//
//  WalkControlsPopover.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Bottom-bar popover that exposes the three composable walk knobs —
//  meander, energy, decade span. Close reverts to the on-open snapshot;
//  Confirm dismisses with current state; Reset wipes back to app
//  defaults but keeps the popover open so the user can confirm or
//  close from there. SongsView reads the values via @AppStorage and
//  rebuilds the deck on dismiss when anything changed.
//

import SwiftUI

struct WalkControlsPopover: View {
	@Binding var controls: WalkControls

	var body: some View {
		NavigationStack {
			WalkControlsForm(controls: $controls)
		}
		.frame(idealWidth: 360)
	}
}

/// Inner view so `@Environment(\.dismiss)` resolves to the popover's
/// presentation, not whatever container the parent lives in. Also
/// owns the on-open snapshot used by Close-as-revert.
private struct WalkControlsForm: View {
	@Binding var controls: WalkControls
	@Environment(\.dismiss) private var dismiss
	@State private var initialSnapshot: WalkControls = .default

	private var isDefault: Bool {
		controls == .default
	}

	var body: some View {
		Form {
			Section {
				meanderSlider
			} header: {
				Text("Meandering")
			} footer: {
				Text("Steady stays close to where the walk began. Meandering picks more surprising next songs.")
			}

			Section {
				Picker("Energy", selection: $controls.energy) {
					ForEach(EnergyBand.allCases) { band in
						Text(band.displayName).tag(band)
					}
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			} header: {
				Text("Energy")
			} footer: {
				Text("Filters the deck by broad genre. Falls back to the whole library if nothing in yours matches.")
			}

			Section {
				Picker("Decade span", selection: $controls.decadeSpan) {
					ForEach(DecadeSpan.allCases) { span in
						Text(span.displayName).tag(span)
					}
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			} header: {
				Text("Decade span")
			} footer: {
				Text("How willing the walk is to bridge eras. Same era keeps consecutive songs close in time.")
			}
		}
		.formStyle(.grouped)
		.toolbar {
			// Close = revert to the snapshot taken when the sheet
			// opened, then dismiss. This makes Close behave like Cancel
			// in iOS sheet UX while still using the iOS 26 `.close`
			// role chrome (the × glyph) the user asked for.
			ToolbarItem(placement: .cancellationAction) {
				Button(role: .close) {
					controls = initialSnapshot
					dismiss()
				}
			}
			// Confirm = dismiss with current state. SongsView's
			// onChange-of-isPresented compares current controls against
			// its own snapshot and rebuilds the deck if anything changed.
			ToolbarItem(placement: .confirmationAction) {
				Button(role: .confirm) {
					dismiss()
				}
			}
			// Reset clears the knobs back to .default but doesn't
			// dismiss — gives the user a chance to confirm or close
			// from the reset state. `.bottomBar` is iOS-only; on
			// macOS `.destructiveAction` keeps the role semantics in
			// the toolbar without the iOS bottom bar.
			#if os(iOS)
				ToolbarItem(placement: .bottomBar) {
					resetButton
				}
			#else
				ToolbarItem(placement: .destructiveAction) {
					resetButton
				}
			#endif
		}
		.onAppear { initialSnapshot = controls }
	}

	private var resetButton: some View {
		Button(role: .destructive) {
			controls = .default
		} label: {
			Label("Reset", systemImage: "arrow.counterclockwise")
		}
		.disabled(isDefault)
	}

	private var meanderSlider: some View {
		// `neutralValue: 0` anchors the fill at the centre so the bar
		// grows outward from the app default — pulling left fills toward
		// Steady, right toward Meandering. `step` produces native tick
		// marks (iOS 26 / macOS 26); the min/max labels replace the
		// hand-rolled HStack we used before the new SDK.
		Slider(
			value: $controls.meander,
			in: -1 ... 1,
			step: 0.1,
			neutralValue: 0
		) {
			Text("Meandering")
		} minimumValueLabel: {
			Text("Steady")
				.font(.caption2)
				.foregroundStyle(.secondary)
		} maximumValueLabel: {
			Text("Meandering")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.labelsHidden()
	}
}

#Preview {
	@Previewable @State var controls = WalkControls.default
	WalkControlsPopover(controls: $controls)
}
