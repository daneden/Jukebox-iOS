//
//  LibraryOverviewView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/05/2026.
//
//  Sheet covering "what Playback sees in your library": analysis progress,
//  library size, energy distribution, energy-over-time scatter, and top genres.
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
	@State private var energyTimeBasis: EnergyTimeBasis = .release

	/// How often the distributions recompute over the cached union while the
	/// sheet is open, tracking the warmer's progress.
	private static let refreshInterval: Duration = .seconds(5)

	var body: some View {
		NavigationStack {
			content
				.navigationTitle("Library analysis")
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
		if let loadError, stats == nil {
			ContentUnavailableView(
				"Couldn't load library",
				systemImage: "exclamationmark.triangle",
				description: Text(loadError)
			)
		} else {
			// Render the whole scaffold immediately (structure + placeholders),
			// filling each section in as its data lands, rather than gating the
			// sheet on one spinner.
			Form {
				analysisSection

				Section {
					librarySizeRow
				} header: {
					Text("Library size")
				} footer: {
					Text("Up to 10,000 songs (most-played, oldest, and newest) are analysed from your library to form playlists.")
				}

				// Energy, scatter and genres come from one classify pass; until
				// it lands each shows a placeholder so layout stays stable.
				if let stats {
					energySection(rows: stats.energyBuckets)
					energyEraSection(stats: stats)
					genresSection(rows: stats.topGenres, total: stats.totalGenreCount)
				} else {
					analyzingSection("Energy")
					analyzingSection("Energy over time")
					analyzingSection("Genres")
				}
			}
			.formStyle(.grouped)
		}
	}

	/// Deck progress reads live from `EmbeddingProgress` (in memory), so it shows
	/// instantly; the library-pool row spins until the snapshot lands.
	private var analysisSection: some View {
		Section {
			analysisRow(
				"Deck",
				embedded: EmbeddingProgress.shared.embeddedCount,
				total: EmbeddingProgress.shared.totalCount
			)
			if let stats {
				analysisRow("Library", embedded: stats.analysisPool.embedded, total: stats.analysisPool.total)
			} else {
				analyzingRow("Library")
			}
		} header: {
			Text("Analysis")
		} footer: {
			Text("Your music library is analysed when the app is open and your device is connected to WiFi, or in the background while charging.")
		}
	}

	/// Placeholder for a union-derived section before its snapshot lands.
	private func analyzingSection(_ title: String) -> some View {
		Section {
			HStack(spacing: 8) {
				ProgressView()
					.controlSize(.small)
				Text("Analyzing your library…")
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		} header: {
			Text(title)
		}
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

	/// `analysisRow`'s layout with a spinner in place of the count.
	private func analyzingRow(_ label: String) -> some View {
		HStack {
			Text(label)
				.font(.subheadline.weight(.medium))
			Spacer()
			ProgressView()
				.controlSize(.small)
		}
	}

	private func energySection(rows: [LibraryStats.EnergyCount]) -> some View {
		// Keep Unclassified in the stack — its share signals how much of the
		// library still lacks sound data, shrinking as analysis runs.
		let unclassified = rows.first { $0.band == nil }?.count ?? 0
		return Section {
			EnergyChart(rows: rows)
		} header: {
			Text("Energy")
		} footer: {
			if unclassified > 0 {
				Text("Unclassified songs fall back to genre and era for walks.")
			}
		}
	}

	private func energyEraSection(stats: LibraryStats) -> some View {
		Section {
			if stats.energyPoints.isEmpty {
				Text("Energy appears here as songs are analyzed.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				Picker("Time basis", selection: $energyTimeBasis) {
					ForEach(EnergyTimeBasis.allCases) { basis in
						Text(basis.label).tag(basis)
							.frame(maxWidth: .infinity)
					}
				}
				.pickerStyle(.segmented)
				.frame(maxWidth: .infinity)
				.labelsHidden()

				EnergyScatter(points: stats.energyPoints, timeBasis: energyTimeBasis)
			}
		} header: {
			Text("Energy over time")
		}
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
					.contentTransition(.numericText())
			}
		}
	}

	// MARK: - Loading

	private func load() async {
		loadError = nil

		// Instant paint from the last persisted snapshot; the expensive union
		// fetch + classify happens in the revalidate loop below.
		if let cached = await LibraryStatsStore.shared.load() {
			stats = cached
		}

		// Library size — one-shot in parallel, not part of the refresh loop.
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

		// Revalidate on a cadence, but only when coverage has advanced, so an
		// idle sheet doesn't re-fetch + re-classify the pool every tick.
		var lastSignature: [Int]?
		var firstPass = true
		while !Task.isCancelled {
			let signature = await LibraryStatsBuilder.coverageSignature()
			if firstPass || stats == nil || signature != lastSignature {
				let outcome = await LibraryStatsBuilder.refresh()
				if Task.isCancelled { break }
				switch outcome {
				case let .computed(fresh):
					withAnimation(.smooth) { stats = fresh }
					lastSignature = signature
					loadError = nil
				case .coalesced:
					// Eager prime is computing — show its result if it landed,
					// else placeholders stay up until the next tick.
					if let reloaded = await LibraryStatsStore.shared.load() {
						withAnimation(.smooth) { stats = reloaded }
					}
				case .failed:
					// Keep any cached snapshot; only surface the empty state with
					// nothing to show.
					if stats == nil {
						loadError = "Couldn’t reach your library. Stats will appear once analysis runs."
					}
				}
				firstPass = false
			}
			try? await Task.sleep(for: Self.refreshInterval)
		}
	}
}

// MARK: - Bar charts

/// Single stacked bar of the library's energy mix — one band-tinted segment
/// per band plus a grey Unclassified segment. Counts ride in the legend.
private struct EnergyChart: View {
	let rows: [LibraryStats.EnergyCount]

	var body: some View {
		Chart(rows) { row in
			BarMark(
				x: .value("Songs", row.count),
				y: .value("Library", "")
			)
			.foregroundStyle(by: .value("Band", row.label))
			.clipShape(row == rows.last
				? UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 8, topTrailing: 8))
				: row == rows.first
				? UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, bottomLeading: 8))
				: UnevenRoundedRectangle(cornerRadii: .init()))
		}
		.chartForegroundStyleScale(
			domain: rows.map(\.label),
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
					.foregroundStyle(.tertiary)
			}
		}
		// rows arrive count-descending → highest genre on top.
		.chartYScale(domain: rows.map(\.label))
		.chartYAxis {
			AxisMarks(position: .leading) {
				AxisValueLabel()
			}
		}
		.chartLegend(.hidden)
		.frame(height: CGFloat(rows.count) * 30)
	}
}

// MARK: - Energy over time scatter

/// Time axis for the energy scatter: release date vs date added to library.
private enum EnergyTimeBasis: String, CaseIterable, Identifiable {
	case release
	case added

	var id: String {
		rawValue
	}

	var label: String {
		switch self {
		case .release: "Release date"
		case .added: "Date added to library"
		}
	}
}

/// One dot per classified song: continuous energy (y) against the caller's
/// chosen time axis (x). The y-axis is labelled at the four band centres so the
/// 0–1 value still reads as Glacial…Intense; songs with no cached BPM sit on
/// their band's centre line until tempo spreads them.
private struct EnergyScatter: View {
	let points: [LibraryStats.EnergyPoint]
	let timeBasis: EnergyTimeBasis

	/// Band labels placed at each band's centre value, so the continuous y-axis
	/// reads in band terms.
	private static let bandTicks: [(value: Double, label: String)] = [
		(0.125, "Glacial"),
		(0.375, "Mellow"),
		(0.625, "Energetic"),
		(0.875, "Intense"),
	]

	private static func date(year: Int) -> Date {
		Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
	}

	/// Points plottable on the current axis. The added view drops songs without
	/// an added date rather than collapse them onto a fake one.
	private var plotted: [LibraryStats.EnergyPoint] {
		timeBasis == .added ? points.filter { $0.addedDate != nil } : points
	}

	private func date(_ point: LibraryStats.EnergyPoint) -> Date {
		(timeBasis == .added ? point.addedDate : point.releaseDate) ?? point.releaseDate
	}

	/// X-axis bounds per basis. Release clamps to 1900–2030 so a stray year-0
	/// date can't drag the auto-ranged scale. Added range-frames to the
	/// library's own lifetime so it fills the axis rather than hugging the edge.
	private var dateDomain: ClosedRange<Date> {
		let dates = plotted.map(date)
		guard let lo = dates.min(), let hi = dates.max() else {
			return Self.date(year: 2015) ... Self.date(year: 2025)
		}
		switch timeBasis {
		case .release:
			let clampedLo = max(Self.date(year: 1900), lo)
			let clampedHi = min(Self.date(year: 2031), hi)
			return clampedLo ... max(clampedHi, clampedLo.addingTimeInterval(1))
		case .added:
			return lo ... max(hi, lo.addingTimeInterval(1))
		}
	}

	var body: some View {
		Chart {
			ForEach(plotted) { point in
				PointMark(
					x: .value("Date", date(point)),
					y: .value("Energy", point.energy)
				)
				// Blend band tints across the energy axis so between-band songs
				// get a mix.
				.foregroundStyle(EnergyBand.color(forEnergy: point.energy))
				.symbolSize(8)
				.opacity(0.45)
			}
		}
		.chartXScale(domain: dateDomain)
		.animation(.smooth(duration: 0.4), value: timeBasis)
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
					if let date = value.as(Date.self) {
						Text(date, format: .dateTime.year()).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.chartLegend(.hidden)
		.frame(height: 200)
	}
}
