//
//  EmbeddingProgressIndicator.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Toolbar button that shows the current gem-deck embedding progress
//  as a circular ring, swaps to a checkmark when complete, and opens a
//  popover with finer-grained detail when tapped.
//
//  The popover is the surface where future "library status" affordances
//  will live — neighborhood breakdowns once clusters exist (#12), a
//  last-embedded ticker, error log if any songs failed to embed, etc.

import SwiftUI

struct EmbeddingProgressIndicator: View {
	let progress: EmbeddingProgress
	@State private var showingPopover = false

	var body: some View {
		if progress.hasDeck {
			Button {
				showingPopover = true
			} label: {
				indicator
			}
			.popover(isPresented: $showingPopover, arrowEdge: .top) {
				EmbeddingProgressPopover(progress: progress)
					.presentationCompactAdaptation(.popover)
			}
			.accessibilityLabel("Library analysis progress")
			.accessibilityValue(accessibilityValue)
		}
	}

	@ViewBuilder
	private var indicator: some View {
		if progress.isComplete {
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

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header

			if !progress.isComplete {
				ProgressView(value: progress.fraction)
			}

			Text(blurb)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding()
		.frame(minWidth: 280, idealWidth: 320)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Library Analysis")
				.font(.headline)
			Text(subtitle)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.contentTransition(.numericText())
		}
	}

	private var subtitle: String {
		if progress.isComplete {
			"All \(progress.totalCount) songs analyzed"
		} else {
			"\(progress.embeddedCount) of \(progress.totalCount) songs analyzed"
		}
	}

	private var blurb: String {
		if progress.isComplete {
			"Every song in your current deck has been analyzed. The dial uses these fingerprints to order songs by sonic similarity. New songs are analyzed automatically when they land in the deck."
		} else {
			"Each song's audio is fingerprinted from its 30-second preview and cached locally. The dial uses these fingerprints to order songs by sonic similarity. The first run takes a few minutes; after that, lookups are instant."
		}
	}
}
