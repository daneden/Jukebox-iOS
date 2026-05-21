//
//  WalkControlsPopover.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Bottom-bar popover that exposes the three composable walk knobs —
//  meander, energy, decade span — plus a reset that returns control to
//  the curated app defaults. SongsView reads the values via @AppStorage
//  and rebuilds the deck when the popover dismisses with changes.
//

import SwiftUI

struct WalkControlsPopover: View {
	@Binding var controls: WalkControls
	let onReset: () -> Void

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

			Section {
				Button(role: .destructive) {
					onReset()
				} label: {
					Label("Reset", systemImage: "arrow.counterclockwise")
						.frame(maxWidth: .infinity)
				}
				.disabled(isDefault)
			}
		}
		.formStyle(.grouped)
		.frame(idealWidth: 360)
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
	WalkControlsPopover(controls: $controls, onReset: { controls = .default })
}
