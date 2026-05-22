//
//  WalkFilterChips.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//

import SwiftUI

/// Capsule tags surfaced above the dial whenever any walk-control knob
/// is off its default. Each active filter is its own glass chip; the
/// energy chip carries the band's tint + a variable font width so the
/// label itself hints at intensity (expanded reads calm, compressed
/// reads tight). A trailing reset button clears every knob back to its
/// app default. Chips wrap onto multiple lines when horizontal room
/// runs out — see `ChipFlow`.
struct WalkFilterChips: View {
	let controls: WalkControls
	let onReset: () -> Void

	private var chips: [WalkFilterChip] {
		var result: [WalkFilterChip] = []

		if controls.energy != .any {
			result.append(WalkFilterChip(
				id: "energy-\(controls.energy.rawValue)",
				label: controls.energy.displayName.uppercased(),
				tint: controls.energy.tint,
				fontWidth: controls.energy.fontWidth
			))
		}

		if !controls.decadeRange.isUnbounded {
			let lo = controls.decadeRange.lower
			let hi = controls.decadeRange.upper
			let label = lo == hi ? "\(lo)s" : "\(lo)s\u{2013}\(hi)s"
			result.append(WalkFilterChip(
				id: "decade-\(lo)-\(hi)",
				label: label,
				tint: nil,
				fontWidth: .standard
			))
		}

		if controls.meander <= -0.05 {
			result.append(WalkFilterChip(id: "meander-steady", label: "Steady", tint: nil, fontWidth: .standard))
		} else if controls.meander >= 0.05 {
			result.append(WalkFilterChip(id: "meander-meandering", label: "Meandering", tint: nil, fontWidth: .standard))
		}

		return result
	}

	var body: some View {
		ChipFlow(spacing: 8, rowSpacing: 8) {
			ForEach(chips) { chip in
				ChipLabel(chip: chip)
					.transition(.scale(scale: 0.6).combined(with: .opacity))
			}
			if !chips.isEmpty {
				ResetChip(action: onReset)
					.transition(.scale(scale: 0.6).combined(with: .opacity))
			}
		}
		.padding(.horizontal, 24)
		.padding(.bottom, 12)
		// macOS draws the wordmark inline above the dial (see `ToolbarLogo`
		// in the VStack), so the chips need explicit breathing room beneath
		// it. iOS hosts the wordmark in the nav bar — no extra gap needed.
		#if os(macOS)
			.padding(.top, chips.isEmpty ? 0 : 16)
		#endif
			.animation(.smooth(duration: 0.3), value: chips)
	}
}

private struct WalkFilterChip: Identifiable, Equatable {
	let id: String
	let label: String
	let tint: Color?
	let fontWidth: Font.Width
}

private struct ChipLabel: View {
	let chip: WalkFilterChip

	var body: some View {
		Text(chip.label)
			.fontWeight(.semibold)
			.fontWidth(chip.fontWidth)
			.foregroundStyle(chip.tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.glassEffect(
				chip.tint.map { .regular.tint($0) } ?? .regular,
				in: .capsule
			)
	}
}

/// Trailing chip rendered after the filter tags. Single tap clears
/// every walk knob back to its app default; the chips animate out via
/// the same scale+opacity transition the data chips use.
private struct ResetChip: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Label("Reset", systemImage: "arrow.counterclockwise")
				.fontWeight(.semibold)
		}
		.controlSize(.large)
		.buttonStyle(.glass)
		.labelStyle(.iconOnly)
		.buttonBorderShape(.circle)
	}
}

/// Minimal flow layout — places subviews left-to-right and wraps to
/// the next row when the proposed width can't fit the next one. Rows
/// are centred horizontally so a single chip sits over the dial's
/// centre line, and a wrapped pair stays balanced.
private struct ChipFlow: Layout {
	var spacing: CGFloat = 8
	var rowSpacing: CGFloat = 8

	private struct Row {
		var indices: [Int] = []
		var sizes: [CGSize] = []
		var width: CGFloat = 0
		var height: CGFloat = 0
	}

	private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
		var rows: [Row] = []
		var current = Row()
		for (index, subview) in subviews.enumerated() {
			let size = subview.sizeThatFits(.unspecified)
			if current.indices.isEmpty {
				current.indices = [index]
				current.sizes = [size]
				current.width = size.width
				current.height = size.height
				continue
			}
			let projected = current.width + spacing + size.width
			if projected > maxWidth {
				rows.append(current)
				current = Row(indices: [index], sizes: [size], width: size.width, height: size.height)
			} else {
				current.indices.append(index)
				current.sizes.append(size)
				current.width = projected
				current.height = max(current.height, size.height)
			}
		}
		if !current.indices.isEmpty { rows.append(current) }
		return rows
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
		guard !subviews.isEmpty else { return .zero }
		let maxWidth = proposal.width ?? .infinity
		let computed = rows(maxWidth: maxWidth, subviews: subviews)
		let height = computed.reduce(CGFloat(0)) { $0 + $1.height }
			+ CGFloat(max(0, computed.count - 1)) * rowSpacing
		let width = computed.map(\.width).max() ?? 0
		return CGSize(width: min(maxWidth, width), height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
		let computed = rows(maxWidth: bounds.width, subviews: subviews)
		var y = bounds.minY
		for row in computed {
			var x = bounds.midX - row.width / 2
			for (i, idx) in row.indices.enumerated() {
				let size = row.sizes[i]
				subviews[idx].place(
					at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
					anchor: .topLeading,
					proposal: ProposedViewSize(size)
				)
				x += size.width + spacing
			}
			y += row.height + rowSpacing
		}
	}
}
