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
//   4. Energy × era — a scatter (Swift Charts PointMark): release year ×
//      continuous energy (0–1), one dot per classified song, colored by
//      band, y-axis labelled at the band centres.
//   5. Top-N genres by frequency.
//
//  Tufte: no legends, direct labels on every axis, colour earns its place
//  (band tints). The scatter resolves from band lines into a cloud as BPM
//  coverage grows; the footer says so. Unclassified songs aren't plotted
//  (no energy value) — their count lives in the Energy section.
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

	/// How often the distributions recompute over the cached union while
	/// the sheet is open, so they track the warmer's progress. Tunable —
	/// the recompute is store-reads + tallies, not a MusicKit fetch.
	private static let refreshInterval: Duration = .seconds(5)

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
					analysisRow("Deck", embedded: stats.deck.embedded, total: stats.deck.total)
					analysisRow("Library", embedded: stats.analysisPool.embedded, total: stats.analysisPool.total)
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

				energySection(rows: stats.energyBuckets)

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

	private func analysisRow(_ label: String, embedded: Int, total: Int) -> some View {
		// Built-in linear progress meter — replaces the hand-rolled
		// Capsule track.
		ProgressView(value: Double(embedded), total: Double(max(total, 1))) {
			HStack {
				Text(label)
					.font(.subheadline.weight(.medium))
				Spacer()
				Text("\(embedded.formatted()) of \(total.formatted())")
					.font(.subheadline)
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
		}
	}

	private func energySection(rows: [LibraryStats.EnergyCount]) -> some View {
		// Include Unclassified in the stack — even when it dominates, its
		// share is the signal: how much of the library has rich sound data
		// for walks, shrinking as analysis runs.
		let unclassified = rows.first { $0.band == nil }?.count ?? 0
		return Section {
			EnergyChart(rows: rows)
		} header: {
			Text("Energy")
		} footer: {
			if unclassified > 0 {
				Text("Unclassified songs aren't sound-analyzed yet — walks fall back to genre and era for them until coverage grows over Wi-Fi.")
			}
		}
	}

	private func energyEraSection(stats: LibraryStats) -> some View {
		Section {
			if stats.energyPoints.isEmpty {
				Text("No songs placed yet — energy appears here as your library is analyzed.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				EnergyScatter(points: stats.energyPoints)
			}
		} header: {
			Text("Energy × era")
		} footer: {
			energyEraFooter(stats: stats)
		}
	}

	private func energyEraFooter(stats: LibraryStats) -> some View {
		let peakText = stats.decadeHistogram.max(by: { $0.count < $1.count })
			.map { "Peak: \(decadeLabel($0.decade)) (\($0.count.formatted()) songs). " } ?? ""
		return Text(
			"\(peakText)Each dot is a song by release year and energy. Songs start on their band's line and spread apart as their tempo is analyzed, so the cloud sharpens as your library fills in (\(stats.classifiedCount.formatted()) of \(stats.analysisPool.total.formatted()) placed)."
		)
	}

	private func genresSection(rows: [LibraryStats.BucketCount], total: Int) -> some View {
		let remaining = max(0, total - rows.count)
		return Section {
			if rows.isEmpty {
				Text("No genres available yet.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				GenreChart(rows: rows)
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

		// The union is the slow part and doesn't change as the caches warm,
		// so fetch it once and recompute the distributions over it below.
		let union: [Song]
		do {
			union = try await LibraryStatsBuilder.librarySnapshot()
		} catch {
			loadError = error.localizedDescription
			isLoading = false
			return
		}

		// Library size — one-shot in parallel; not part of the refresh loop.
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

		stats = await LibraryStatsBuilder.stats(deck: deckSnapshot(), over: union)
		isLoading = false

		// Live refresh: recompute over the cached union as the warmer fills
		// the genre / embedding / BPM caches, so the bars and scatter grow
		// while the sheet is open. The `.task` cancels this when it closes.
		while !Task.isCancelled {
			try? await Task.sleep(for: Self.refreshInterval)
			if Task.isCancelled { break }
			let fresh = await LibraryStatsBuilder.stats(deck: deckSnapshot(), over: union)
			withAnimation(.smooth) { stats = fresh }
		}
	}

	private func deckSnapshot() -> LibraryStats.ProgressCounts {
		LibraryStats.ProgressCounts(
			embedded: EmbeddingProgress.shared.embeddedCount,
			total: EmbeddingProgress.shared.totalCount
		)
	}

	private func decadeLabel(_ decade: Int) -> String {
		// 1970 → "1970s". The lowercased `s` keeps the label scannable as
		// a plural; "1970S" reads like a model number.
		"\(decade)s"
	}
}

// MARK: - Bar charts

/// Single stacked bar showing the library's energy *mix* — one band-tinted
/// segment per band (Glacial→Intense), plus a grey Unclassified segment
/// whose share signals how much of the library still lacks rich sound data.
/// Counts ride in the legend so they're not lost in the thin segments.
private struct EnergyChart: View {
	let rows: [LibraryStats.EnergyCount]

	/// Legend entry per band carries the count, e.g. "Mellow  340".
	private func legendLabel(_ row: LibraryStats.EnergyCount) -> String {
		"\(row.label)  \(row.count.formatted())"
	}

	var body: some View {
		Chart(rows) { row in
			BarMark(
				x: .value("Songs", row.count),
				y: .value("Library", "")
			)
			.foregroundStyle(by: .value("Band", legendLabel(row)))
		}
		.chartForegroundStyleScale(
			domain: rows.map(legendLabel),
			range: rows.map { $0.band?.tint ?? .secondary }
		)
		.chartXAxis(.hidden)
		.chartYAxis(.hidden)
		.chartPlotStyle { $0.frame(height: 28) }
		.chartLegend(position: .bottom, alignment: .leading)
	}
}

/// Horizontal bar per top genre, single neutral fill, count trailing.
private struct GenreChart: View {
	let rows: [LibraryStats.BucketCount]

	var body: some View {
		Chart(rows) { row in
			BarMark(
				x: .value("Songs", row.count),
				y: .value("Genre", row.label)
			)
			.foregroundStyle(Color.secondary)
			.cornerRadius(4)
			.annotation(position: .trailing, alignment: .leading) {
				Text(row.count, format: .number)
					.font(.caption)
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
		}
		// rows are sorted by count descending → highest genre at the top.
		.chartYScale(domain: rows.map(\.label))
		.chartXAxis(.hidden)
		.chartYAxis {
			AxisMarks(position: .leading) {
				AxisValueLabel()
			}
		}
		.chartLegend(.hidden)
		.frame(height: CGFloat(rows.count) * 30)
	}
}

// MARK: - Energy × era scatter

/// One dot per classified song: release year (x) × continuous energy (y),
/// colored by band. Finer than bucketing into bands — energy is a 0–1
/// scalar (band centre nudged by tempo), so the dots resolve into a cloud
/// as BPM coverage grows. The y-axis is labelled at the four band centres
/// so the continuous value still reads as Glacial…Intense. Songs with no
/// cached BPM land exactly on their band's centre line until tempo spreads
/// them — see the section footer.
private struct EnergyScatter: View {
	let points: [LibraryStats.EnergyPoint]

	/// Energy → band label, placed at each band's centre value so the
	/// continuous y-axis still reads in band terms.
	private static let bandTicks: [(value: Double, label: String)] = [
		(0.125, "Glacial"),
		(0.375, "Mellow"),
		(0.625, "Energetic"),
		(0.875, "Intense"),
	]

	/// Clamp the year axis to plausible bounds: without an explicit domain
	/// Charts auto-ranged ~0–3000, and bad release-date metadata can drop a
	/// stray point at year 0 — clamping fixes the scale and clips outliers.
	private var yearDomain: ClosedRange<Int> {
		let years = points.map(\.year)
		let lo = max(1900, years.min() ?? 1900)
		let hi = min(2030, years.max() ?? 2030)
		return lo ... max(lo + 1, hi)
	}

	var body: some View {
		Chart(points) { point in
			PointMark(
				x: .value("Year", point.year),
				y: .value("Energy", point.energy)
			)
			.foregroundStyle(point.band.tint)
			.symbolSize(16)
			.opacity(0.45)
		}
		.chartXScale(domain: yearDomain)
		.chartYScale(domain: 0 ... 1)
		.chartYAxis {
			AxisMarks(values: Self.bandTicks.map(\.value)) { value in
				AxisGridLine()
				AxisValueLabel {
					if let v = value.as(Double.self),
					   let tick = Self.bandTicks.first(where: { abs($0.value - v) < 0.0001 })
					{
						Text(tick.label).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartXAxis {
			AxisMarks { value in
				AxisGridLine()
				AxisValueLabel {
					if let year = value.as(Int.self) {
						Text(verbatim: String(year)).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartLegend(.hidden)
		.frame(height: 200)
	}
}
