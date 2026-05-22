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
	/// Min/max decades observed in the user's candidate pool — when
	/// provided, the range slider constrains its thumbs to this
	/// window so they don't wander into empty decades. Nil means
	/// fall back to the static 1900–2030 bounds.
	let libraryDecadeBounds: ClosedRange<Int>?
	/// Size of the currently-built deck after filters, surfaced as a
	/// summary row so the user can see when their filters are biting
	/// hard. Nil while the deck hasn't built yet (cold launch).
	let poolSize: Int?

	var body: some View {
		NavigationStack {
			WalkControlsForm(
				controls: $controls,
				libraryDecadeBounds: libraryDecadeBounds,
				poolSize: poolSize
			)
		}
		.frame(idealWidth: 360)
	}
}

/// Inner view so `@Environment(\.dismiss)` resolves to the popover's
/// presentation, not whatever container the parent lives in. Also
/// owns the on-open snapshot used by Close-as-revert.
private struct WalkControlsForm: View {
	@Binding var controls: WalkControls
	let libraryDecadeBounds: ClosedRange<Int>?
	let poolSize: Int?
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
				DecadeRangeSlider(
					range: $controls.decadeRange,
					bounds: libraryDecadeBounds
				)
			} header: {
				Text("Decade range")
			} footer: {
				Text("Only songs released in this range make it into the deck. Drag both thumbs to the ends for no filter.")
			}

			if let count = poolSize {
				Section {
					PoolSummaryRow(count: count)
				}
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
				ToolbarSpacer(placement: .bottomBar)

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

/// Visual summary of how many songs survived the current filter
/// stack. Reflects the deck *as currently built* — when the user
/// changes controls and confirms, the next time they reopen the
/// popover the count reflects the new deck. Severity tints + an
/// inline warning icon make low counts hard to miss.
private struct PoolSummaryRow: View {
	let count: Int

	private enum Severity {
		case fine, low, veryLow

		var tint: Color {
			switch self {
			case .fine: .secondary
			case .low: .orange
			case .veryLow: .red
			}
		}

		var icon: String? {
			switch self {
			case .fine: nil
			case .low, .veryLow: "exclamationmark.triangle.fill"
			}
		}
	}

	private var severity: Severity {
		switch count {
		case ..<30: .veryLow
		case ..<100: .low
		default: .fine
		}
	}

	private var hint: String? {
		switch severity {
		case .fine: nil
		case .low: "Loosen a filter for more variety."
		case .veryLow: "Filters are very strict — try widening the decade range or switching Energy to Any."
		}
	}

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			if let icon = severity.icon {
				Image(systemName: icon)
					.foregroundStyle(severity.tint)
					.font(.callout)
					.padding(.top, 2)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text("\(count) \(count == 1 ? "song" : "songs") in your deck")
					.font(.callout.weight(.medium))
					.foregroundStyle(severity == .fine ? .primary : severity.tint)
				if let hint {
					Text(hint)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer(minLength: 0)
		}
		.accessibilityElement(children: .combine)
	}
}

#Preview {
	@Previewable @State var controls = WalkControls.default
	WalkControlsPopover(
		controls: $controls,
		libraryDecadeBounds: 1960 ... 2020,
		poolSize: 42
	)
}
