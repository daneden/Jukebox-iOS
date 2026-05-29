//
//  LibraryOverviewView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/05/2026.
//
//  Full-screen sheet opened from the toolbar analysis-progress popover.
//  Surfaces six facets of "what Playback sees in your library" in one
//  scrollable layout:
//
//   1. Deck embedding progress (count + thin bar).
//   2. Library-analysis embedding progress, capped at the warmer's 10k
//      pool size.
//   3. Total library size (paginated; settles after the union returns).
//   4. Energy-band distribution across the analysis pool, including an
//      Unclassified bucket for songs the centroids can't place.
//   5. Decade histogram (Swift Charts; bar-per-decade, baseline only).
//   6. Top-N genres by `genreNames` frequency.
//
//  Tufte: no legends, no gridlines beyond the histogram baseline, direct
//  labels at every row, single colour for non-categorical bars. Every
//  visual element earns its ink.
//

import Charts
import MusicKit
import SwiftUI

struct LibraryOverviewView: View {
	@Environment(\.dismiss) private var dismiss

	@State private var stats: LibraryStats?
	@State private var librarySize: Int?
	@State private var librarySizeFailed = false
	@State private var loadError: String?
	@State private var isLoading = true

	var body: some View {
		NavigationStack {
			content
				.navigationTitle("Library overview")
				.inlineNavigationTitle()
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button(role: .close) { dismiss() }
					}
				}
				.task { await load() }
		}
		#if os(macOS)
		.frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 720)
		#endif
	}

	@ViewBuilder
	private var content: some View {
		if isLoading, stats == nil {
			loadingState
		} else if let stats {
			ScrollView {
				VStack(alignment: .leading, spacing: 32) {
					analysisSection(stats: stats)
					librarySizeSection
					energySection(rows: stats.energyBuckets)
					decadesSection(rows: stats.decadeHistogram)
					genresSection(rows: stats.topGenres, total: stats.totalGenreCount)
				}
				.padding(.horizontal, 24)
				.padding(.vertical, 20)
			}
		} else {
			ContentUnavailableView(
				"Couldn't load library",
				systemImage: "exclamationmark.triangle",
				description: Text(loadError ?? "Try again in a moment.")
			)
		}
	}

	private var loadingState: some View {
		VStack(spacing: 12) {
			ProgressView()
			Text("Reading your library…")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - Sections

	private func analysisSection(stats: LibraryStats) -> some View {
		VStack(alignment: .leading, spacing: 16) {
			sectionTitle("Analysis")

			ProgressRow(
				label: "Deck",
				embedded: stats.deck.embedded,
				total: stats.deck.total
			)

			ProgressRow(
				label: "Library",
				embedded: stats.analysisPool.embedded,
				total: stats.analysisPool.total
			)

			Text("New songs are analyzed automatically over Wi-Fi — while you're in the app, and in the background while charging.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private var librarySizeSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			sectionTitle("Library size")

			HStack(alignment: .firstTextBaseline, spacing: 8) {
				if let librarySize {
					Text(librarySize, format: .number)
						.font(.system(.largeTitle, design: .rounded).weight(.semibold))
						.monospacedDigit()
						.contentTransition(.numericText())
					Text("songs")
						.font(.title3)
						.foregroundStyle(.secondary)
				} else if librarySizeFailed {
					Text("Unavailable")
						.font(.title3)
						.foregroundStyle(.secondary)
				} else {
					HStack(spacing: 8) {
						ProgressView()
							.controlSize(.small)
						Text("Counting…")
							.font(.title3)
							.foregroundStyle(.secondary)
					}
				}
			}

			Text("Analysis is capped at the 10,000 songs most likely to surface in a deck (highest play count, oldest in your library, most recently added).")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func energySection(rows: [LibraryStats.EnergyCount]) -> some View {
		let maxCount = max(rows.map(\.count).max() ?? 1, 1)
		return VStack(alignment: .leading, spacing: 12) {
			sectionTitle("Energy")

			VStack(spacing: 10) {
				ForEach(rows) { row in
					BarRow(
						label: row.label,
						count: row.count,
						maxCount: maxCount,
						tint: row.band?.tint ?? .secondary,
						showSwatch: row.band != nil
					)
				}
			}
		}
	}

	private func decadesSection(rows: [LibraryStats.DecadeCount]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionTitle("Eras")

			if rows.isEmpty {
				Text("No release dates available yet.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				DecadeHistogram(rows: rows)
				if let peak = rows.max(by: { $0.count < $1.count }) {
					Text("Peak: \(decadeLabel(peak.decade)) (\(peak.count.formatted()) songs)")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private func genresSection(rows: [LibraryStats.BucketCount], total: Int) -> some View {
		let maxCount = max(rows.map(\.count).max() ?? 1, 1)
		let remaining = max(0, total - rows.count)
		return VStack(alignment: .leading, spacing: 12) {
			sectionTitle("Genres")

			if rows.isEmpty {
				Text("No genres available yet.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				VStack(spacing: 10) {
					ForEach(rows) { row in
						BarRow(
							label: row.label,
							count: row.count,
							maxCount: maxCount,
							tint: .secondary,
							showSwatch: false
						)
					}
				}

				if remaining > 0 {
					Text("+ \(remaining.formatted()) more")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	// MARK: - Loading

	private func load() async {
		isLoading = true
		loadError = nil
		stats = nil
		librarySize = nil
		librarySizeFailed = false

		let deckSnapshot = LibraryStats.ProgressCounts(
			embedded: EmbeddingProgress.shared.embeddedCount,
			total: EmbeddingProgress.shared.totalCount
		)

		// Pool stats and library size run in parallel — the size cell
		// updates independently when its async finishes.
		async let poolTask = Task {
			try await LibraryStatsBuilder.buildPoolStats(deck: deckSnapshot)
		}.value

		Task {
			let count = await LibraryStatsBuilder.paginatedSongCount()
			await MainActor.run {
				if let count {
					withAnimation(.smooth) { librarySize = count }
				} else {
					librarySizeFailed = true
				}
			}
		}

		do {
			let pool = try await poolTask
			stats = pool
		} catch {
			loadError = error.localizedDescription
		}
		isLoading = false
	}

	private func decadeLabel(_ decade: Int) -> String {
		// 1970 → "1970s". The lowercased `s` keeps the label scannable as
		// a plural; "1970S" reads like a model number.
		"\(decade)s"
	}

	private func sectionTitle(_ text: String) -> some View {
		Text(text)
			.font(.headline)
			.foregroundStyle(.primary)
	}
}

// MARK: - Row primitives

private struct ProgressRow: View {
	let label: String
	let embedded: Int
	let total: Int

	private var fraction: Double {
		guard total > 0 else { return 0 }
		return Double(embedded) / Double(total)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline) {
				Text(label)
					.font(.subheadline.weight(.medium))
				Spacer()
				Text("\(embedded.formatted()) of \(total.formatted())")
					.font(.subheadline)
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
			ProgressTrack(fraction: fraction)
		}
	}
}

private struct ProgressTrack: View {
	let fraction: Double

	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: .leading) {
				Capsule()
					.fill(.tertiary)
					.frame(height: 4)
				Capsule()
					.fill(Color.accentColor)
					.frame(width: max(0, geo.size.width * fraction), height: 4)
					.animation(.smooth(duration: 0.4), value: fraction)
			}
		}
		.frame(height: 4)
	}
}

private struct BarRow: View {
	let label: String
	let count: Int
	let maxCount: Int
	let tint: Color
	let showSwatch: Bool

	private var fraction: Double {
		guard maxCount > 0 else { return 0 }
		return Double(count) / Double(maxCount)
	}

	var body: some View {
		HStack(spacing: 12) {
			HStack(spacing: 8) {
				if showSwatch {
					RoundedRectangle(cornerRadius: 2)
						.fill(tint)
						.frame(width: 6, height: 14)
				} else {
					// Keep the leading edge aligned across rows whether
					// or not a swatch is present, so labels line up.
					Color.clear.frame(width: 6, height: 14)
				}
				Text(label)
					.font(.subheadline)
					.lineLimit(1)
					.truncationMode(.tail)
			}
			.frame(width: 132, alignment: .leading)

			GeometryReader { geo in
				ZStack(alignment: .leading) {
					Capsule()
						.fill(.tertiary)
						.frame(height: 6)
					Capsule()
						.fill(tint)
						.frame(width: max(0, geo.size.width * fraction), height: 6)
				}
			}
			.frame(height: 6)

			Text(count, format: .number)
				.font(.subheadline)
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.frame(minWidth: 56, alignment: .trailing)
		}
	}
}

// MARK: - Decade histogram

private struct DecadeHistogram: View {
	let rows: [LibraryStats.DecadeCount]

	/// "'10", "'20" … the categorical x value AND the axis label. Plotting
	/// the raw Int decade put the bars on a continuous 1900–2020 axis where
	/// each was ~1 unit wide and rendered invisibly; a discrete label per
	/// decade gives Swift Charts a real band to size each bar against.
	private func label(_ decade: Int) -> String {
		"'\(String(decade % 100).leftPadded(to: 2, with: "0"))"
	}

	var body: some View {
		Chart {
			ForEach(rows) { row in
				BarMark(
					x: .value("Decade", label(row.decade)),
					y: .value("Count", row.count),
					width: .ratio(0.8)
				)
				.foregroundStyle(Color.accentColor)
				.cornerRadius(2)
			}
		}
		// Pin the category order to ascending decade (rows are pre-sorted);
		// otherwise Swift Charts would order the string categories itself.
		.chartXScale(domain: rows.map { label($0.decade) })
		.chartXAxis {
			AxisMarks { value in
				AxisValueLabel {
					if let label = value.as(String.self) {
						Text(label)
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartYAxis(.hidden)
		.chartPlotStyle { plot in
			plot.background(.clear)
		}
		.frame(height: 140)
	}
}

private extension String {
	func leftPadded(to length: Int, with character: Character) -> String {
		if count >= length { return self }
		return String(repeating: character, count: length - count) + self
	}
}
