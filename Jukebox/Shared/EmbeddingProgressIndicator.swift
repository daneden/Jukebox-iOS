//
//  EmbeddingProgressIndicator.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Toolbar button showing gem-deck embedding progress as a ring, swapping to
//  a checkmark when complete, opening a detail popover on tap.

import SwiftUI

struct EmbeddingProgressIndicator: View {
	let progress: EmbeddingProgress
	@State private var showingPopover = false
	@State private var showingDetails = false

	var body: some View {
		Button {
			showingPopover = true
		} label: {
			indicator
		}
		.popover(isPresented: $showingPopover, arrowEdge: .top) {
			EmbeddingProgressPopover(progress: progress) {
				showingPopover = false
				showingDetails = true
			}
			.presentationCompactAdaptation(.popover)
		}
		.sheet(isPresented: $showingDetails) {
			LibraryOverviewView()
		}
		.accessibilityLabel("Library analysis progress")
		.accessibilityValue(accessibilityValue)
		// Eager prime: persist the library-overview snapshot now so the sheet
		// paints instantly instead of waiting on the union fetch. .utility so
		// it doesn't compete with the dial.
		.task(priority: .utility) {
			await LibraryStatsBuilder.refresh()
		}
	}

	private var indicator: some View {
		Group {
			if !progress.hasDeck {
				Image(systemName: "waveform.badge.magnifyingglass")
					.symbolRenderingMode(.hierarchical)
					.foregroundStyle(.tint)
			} else if progress.isComplete {
				Image(systemName: "checkmark.circle.fill")
					.symbolRenderingMode(.hierarchical)
					.foregroundStyle(.tint)
			} else {
				ZStack {
					Circle()
						.stroke(.tertiary, lineWidth: 2)
					Circle()
						.trim(from: 0, to: progress.fraction)
						.stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.smooth(duration: 0.4), value: progress.fraction)
				}
				.frame(width: 18, height: 18)
			}
		}
		.transition(.blurReplace)
		.accessibilityLabel("Library analysis")
	}

	private var accessibilityValue: String {
		if progress.isComplete {
			"All \(progress.totalCount) songs analyzed"
		} else {
			"\(progress.embeddedCount) of \(progress.totalCount) songs analyzed"
		}
	}
}

// MARK: - Popover

private struct EmbeddingProgressPopover: View {
	let progress: EmbeddingProgress
	let onShowDetails: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header

			if !progress.isComplete {
				ProgressView(value: progress.fraction)
			}

			Text(blurb)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Button(action: onShowDetails) {
				Label("See analysis details", systemImage: "waveform.badge.magnifyingglass")
					.contentShape(.rect)
			}
			.buttonStyle(.glass)
			.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.padding()
		.frame(minWidth: 280, idealWidth: 320)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Library analysis")
				.font(.headline)
			Text(subtitle)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.contentTransition(.numericText())
		}
	}

	private var subtitle: String {
		if progress.isComplete {
			"All \(progress.totalCount) songs in rotation analyzed"
		} else {
			"\(progress.embeddedCount) of \(progress.totalCount) songs in rotation analyzed"
		}
	}

	private var blurb: String {
		if progress.isComplete {
			"Analysis of songs in rotation is complete. Your full music library (up to 10,000 songs) is analysed in the background."
		} else {
			"Audio fingerprints from 30-second previews, cached locally. Used to order songs by sonic similarity."
		}
	}
}
