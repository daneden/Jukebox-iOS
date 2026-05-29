//
//  LibraryOverviewView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/05/2026.
//
//  Full-screen sheet opened from the toolbar analysis-progress popover.
//  Grouped `Form` sections covering "what Playback sees in your library":
//
//   1. Analysis — deck + library embedding progress (capped at the
//      warmer's 10k pool).
//   2. Library size (paginated; settles after the union returns).
//   3. Energy — band distribution across the analysis pool, including an
//      Unclassified bucket for songs the classifier can't place yet.
//   4. Energy × era — a heatmap (Swift Charts RectangleMark): decades
//      across, energy bands + Unclassified up, each cell shaded by count.
//   5. Top-N genres by frequency.
//
//  Tufte: no legends, direct labels on every axis/row, colour earns its
//  place (band tints + count-as-opacity in the heatmap). The Unclassified
//  row keeps the heatmap populated before analysis warms and lets it
//  visibly fill as songs move into bands.
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
			Form {
				Section {
					ProgressRow(label: "Deck", embedded: stats.deck.embedded, total: stats.deck.total)
					ProgressRow(label: "Library", embedded: stats.analysisPool.embedded, total: stats.analysisPool.total)
				} header: {
					Text("Analysis")
				} footer: {
					Text("New songs are analyzed automatically over Wi-Fi — while you're in the app, and in the background while charging.")
				}

				Section {
					librarySizeRow
				} header: {
					Text("Library size")
				} footer: {
					Text("Analysis is capped at the 10,000 songs most likely to surface in a deck (highest play count, oldest in your library, most recently added).")
				}

				Section("Energy") {
					energyBars(rows: stats.energyBuckets)
				}

				energyEraSection(stats: stats)

				genresSection(rows: stats.topGenres, total: stats.totalGenreCount)
			}
			.formStyle(.grouped)
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

	private var librarySizeRow: some View {
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
	}

	private func energyBars(rows: [LibraryStats.EnergyCount]) -> some View {
		let maxCount = max(rows.map(\.count).max() ?? 1, 1)
		return VStack(spacing: 10) {
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

	private func energyEraSection(stats: LibraryStats) -> some View {
		Section {
			if stats.energyByEra.isEmpty {
				Text("No release dates available yet.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				EnergyEraHeatmap(cells: stats.energyByEra)
			}
		} header: {
			Text("Energy × era")
		} footer: {
			energyEraFooter(stats: stats)
		}
	}

	@ViewBuilder
	private func energyEraFooter(stats: LibraryStats) -> some View {
		if let peak = stats.decadeHistogram.max(by: { $0.count < $1.count }) {
			Text("Peak: \(decadeLabel(peak.decade)) (\(peak.count.formatted()) songs). Cell shade is song count; energy bands fill in as analysis catches up.")
		}
	}

	private func genresSection(rows: [LibraryStats.BucketCount], total: Int) -> some View {
		let maxCount = max(rows.map(\.count).max() ?? 1, 1)
		let remaining = max(0, total - rows.count)
		return Section {
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
			}
		} header: {
			Text("Genres")
		} footer: {
			if remaining > 0 {
				Text("+ \(remaining.formatted()) more")
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

// MARK: - Energy × era heatmap

/// Decades across the x-axis, energy bands (+ an Unclassified row) up the
/// y-axis, each cell shaded by song count. Replaces the 1-D decade
/// histogram: it shows the era distribution (columns), the energy
/// distribution (rows), AND their joint shape in one matrix. Categorical
/// axes both ways — plotting the decade as a raw Int collapsed the bars
/// onto a continuous span and rendered them invisibly.
private struct EnergyEraHeatmap: View {
	let cells: [LibraryStats.EnergyEraCell]

	// Rows low → high energy, Unclassified last. Pinned so Swift Charts
	// doesn't reorder the categories itself.
	private static let bandOrder: [EnergyBand] = [.glacial, .mellow, .energetic, .intense]
	private static let unclassifiedLabel = "Unclassified"

	private var maxCount: Int {
		max(cells.map(\.count).max() ?? 1, 1)
	}

	private var decades: [Int] {
		Array(Set(cells.map(\.decade))).sorted()
	}

	private func decadeLabel(_ decade: Int) -> String {
		"'\(String(decade % 100).leftPadded(to: 2, with: "0"))"
	}

	private func rowLabel(_ band: EnergyBand?) -> String {
		band?.displayName ?? Self.unclassifiedLabel
	}

	/// sqrt so small cells stay visible while the (currently dominant)
	/// Unclassified mass doesn't wash everything else out; floored so a
	/// populated cell is never fully transparent.
	private func opacity(_ count: Int) -> Double {
		0.15 + 0.85 * (Double(count) / Double(maxCount)).squareRoot()
	}

	var body: some View {
		Chart(cells) { cell in
			RectangleMark(
				x: .value("Era", decadeLabel(cell.decade)),
				y: .value("Energy", rowLabel(cell.band))
			)
			.foregroundStyle((cell.band?.tint ?? .secondary).opacity(opacity(cell.count)))
			.cornerRadius(3)
		}
		.chartXScale(domain: decades.map(decadeLabel))
		// Swift Charts puts the first y-domain entry at the top, so feed it
		// top→bottom (Intense…Glacial, then Unclassified) to read bottom-up
		// as Unclassified → Glacial → Mellow → Energetic → Intense.
		.chartYScale(domain: Self.bandOrder.reversed().map(\.displayName) + [Self.unclassifiedLabel])
		.chartXAxis {
			AxisMarks { value in
				AxisValueLabel {
					if let label = value.as(String.self) {
						Text(label).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartYAxis {
			AxisMarks { value in
				AxisValueLabel {
					if let label = value.as(String.self) {
						Text(label).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartLegend(.hidden)
		.frame(height: 170)
	}
}

private extension String {
	func leftPadded(to length: Int, with character: Character) -> String {
		if count >= length { return self }
		return String(repeating: character, count: length - count) + self
	}
}
