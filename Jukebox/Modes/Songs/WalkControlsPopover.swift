//
//  WalkControlsPopover.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Bottom-bar popover for the walk knobs. Close reverts to the on-open
//  snapshot; Confirm dismisses with current state; Reset wipes to
//  defaults but keeps the popover open.
//

import SwiftUI

struct WalkControlsPopover: View {
	@Binding var controls: WalkControls
	/// Decades observed in the candidate pool; constrains the range slider
	/// so thumbs don't wander into empty decades. Nil falls back to the
	/// static 1900–2030 bounds.
	let libraryDecadeBounds: ClosedRange<Int>?
	/// Deck size after filters. Nil before the deck has built (cold launch).
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
/// presentation, not the parent's container.
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
				Text("Variety")
			} footer: {
				Text("Steady keeps consecutive songs sounding similar. Varied picks more surprising next songs.")
			}

			Section {
				Toggle("Filter by energy", isOn: energyEnabled)
				if controls.energy.isActive {
					energyTargetSlider
					energyWindowSlider
				}
			} header: {
				Text("Energy")
			} footer: {
				Text(controls.energy.isActive
					? "Keeps songs whose energy sits near the target. A wider range trades focus for variety."
					: "Filter the deck by how energetic songs sound — calm ambient through driving, intense tracks. Off uses your whole library.")
			}

			Section {
				DecadeRangeSlider(
					range: $controls.decadeRange,
					bounds: libraryDecadeBounds
				)
			} header: {
				Text("Decade range")
			} footer: {
				Text("Only songs released in this range appear. Drag both thumbs to the ends for no filter.")
			}

			if let count = poolSize {
				Section {
					PoolSummaryRow(count: count)
				}
			}
		}
		.formStyle(.grouped)
		.toolbar {
			// Close reverts to the on-open snapshot then dismisses —
			// Cancel semantics under the iOS 26 `.close` role chrome.
			ToolbarItem(placement: .cancellationAction) {
				Button(role: .close) {
					controls = initialSnapshot
					dismiss()
				}
			}
			// Confirm dismisses with current state; SongsView rebuilds
			// the deck on dismiss if anything changed.
			ToolbarItem(placement: .confirmationAction) {
				Button(role: .confirm) {
					dismiss()
				}
			}
			// Reset to .default without dismissing. `.bottomBar` is
			// iOS-only; macOS uses `.destructiveAction` instead.
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
		// `neutralValue: 0` anchors the fill at centre so the bar grows
		// outward from the default. `step` produces native tick marks.
		Slider(
			value: $controls.meander,
			in: -1 ... 1,
			step: 0.1,
			neutralValue: 0
		) {
			Text("Variety")
		} minimumValueLabel: {
			Text("Steady")
				.font(.caption2)
				.foregroundStyle(.secondary)
		} maximumValueLabel: {
			Text("Varied")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.labelsHidden()
	}

	// MARK: Energy

	/// Toggling on seeds a mid-axis target; off clears it (nil) but keeps
	/// the window for next time.
	private var energyEnabled: Binding<Bool> {
		Binding(
			get: { controls.energy.isActive },
			set: { on in controls.energy.target = on ? 0.5 : nil }
		)
	}

	private var energyTargetBinding: Binding<Double> {
		Binding(
			get: { controls.energy.target ?? 0.5 },
			set: { controls.energy.target = $0 }
		)
	}

	private var energyTargetSlider: some View {
		let target = controls.energy.target ?? 0.5
		let band = EnergyBand.forValue(target)
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(band.displayName)
					.font(.subheadline.weight(.medium))
					.fontWidth(band.fontWidth)
					.foregroundStyle(band.tint)
				Spacer()
				Text("≈ \(target, format: .number.precision(.fractionLength(2)))")
					.font(.subheadline)
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
			Slider(value: energyTargetBinding, in: 0 ... 1) {
				Text("Energy")
			} minimumValueLabel: {
				Text("Calm").font(.caption2).foregroundStyle(.secondary)
			} maximumValueLabel: {
				Text("Intense").font(.caption2).foregroundStyle(.secondary)
			}
			.labelsHidden()
			.tint(band.tint)
		}
	}

	private var energyWindowSlider: some View {
		Slider(
			value: $controls.energy.window,
			in: EnergyFilter.minWindow ... EnergyFilter.maxWindow
		) {
			Text("Range")
		} minimumValueLabel: {
			Text("Focused").font(.caption2).foregroundStyle(.secondary)
		} maximumValueLabel: {
			Text("Wide").font(.caption2).foregroundStyle(.secondary)
		}
		.labelsHidden()
	}
}

/// How many songs survived the current filter stack, with severity
/// tints + a warning icon so low counts are hard to miss.
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
		case .veryLow: "Filters are very strict — try widening the decade range, widening the energy range, or turning the energy filter off."
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
				Text("\(count) \(count == 1 ? "song" : "songs") available")
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
