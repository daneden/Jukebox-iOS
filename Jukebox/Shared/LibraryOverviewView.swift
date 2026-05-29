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
//   4. Energy over time — a scatter (Swift Charts PointMark): continuous
//      energy (0–1) against a release-year or date-added time axis (user
//      toggles), one dot per classified song, colored by band, y-axis
//      labelled at the band centres. Release reads era; date-added reads
//      how taste shifts over a library's lifetime.
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
	@State private var energyTimeBasis: EnergyTimeBasis = .release

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
		if let loadError, stats == nil {
			ContentUnavailableView(
				"Couldn't load library",
				systemImage: "exclamationmark.triangle",
				description: Text(loadError)
			)
		} else {
			// Progressive: render the whole scaffold immediately so a cold open
			// shows structure + live deck progress + "Counting…"/"Analyzing…"
			// placeholders right away, then fills each section in as its data
			// lands — instead of a blank spinner gating the entire sheet.
			Form {
				analysisSection

				Section {
					librarySizeRow
				} header: {
					Text("Library size")
				} footer: {
					Text("Up to 10,000 songs (most-played, oldest, and newest) are analysed from your library to form playlists.")
				}

				// Energy, the era scatter and genres all come from one classify
				// pass — until it lands, each shows its header over an analysing
				// row so the layout is stable when the charts swap in.
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

	/// Deck progress reads live from `EmbeddingProgress` (in memory, no union),
	/// so it shows the instant the sheet opens. The library-pool row needs the
	/// snapshot, so it shows an inline spinner until that lands.
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

	/// Placeholder section shown for a union-derived section before the snapshot
	/// lands — its real header over a small "analysing" row.
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

	/// Matches `analysisRow`'s label-left layout but with a spinner in place of
	/// the count, for a metric still being computed.
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

		// Instant paint: the last persisted snapshot, if any. Every open after
		// the first shows real data immediately with zero MusicKit work — the
		// expensive union fetch + classify happens in the revalidate below.
		if let cached = await LibraryStatsStore.shared.load() {
			stats = cached
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

		// Revalidate now, then on a cadence while the sheet is open — but only
		// when analysis has actually advanced (the coverage fingerprint moved),
		// so an idle sheet doesn't re-fetch + re-classify the pool every tick.
		// The `.task` cancels this when the sheet closes.
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
					// The eager prime is computing — show its result if it has
					// landed; otherwise the section placeholders stay up and the
					// next tick (or the prime's completion) fills them in.
					if let reloaded = await LibraryStatsStore.shared.load() {
						withAnimation(.smooth) { stats = reloaded }
					}
				case .failed:
					// Keep any cached snapshot on screen; only surface the empty
					// state when there's genuinely nothing to show.
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

/// Single stacked bar showing the library's energy *mix* — one band-tinted
/// segment per band (Glacial→Intense), plus a grey Unclassified segment
/// whose share signals how much of the library still lacks rich sound data.
/// Counts ride in the legend so they're not lost in the thin segments.
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
		// rows are sorted by count descending → highest genre at the top.
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

/// Time axis for the energy scatter: when a song was released vs when it was
/// added to the library. Release reads as era; added reads as how taste
/// shifts over a library's lifetime.
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

/// One dot per classified song: continuous energy (y) against a time axis
/// (x) the caller chooses — the song's release date, or the date it was added
/// to the library. Dates plot on a temporal axis (not bucketed to the year),
/// so songs spread across months. Finer than bucketing into bands — energy is
/// a 0–1 scalar (band centre nudged by tempo), so the dots resolve into a
/// cloud as BPM coverage grows. The y-axis is labelled at the four band
/// centres so the continuous value still reads as Glacial…Intense. Songs with
/// no cached BPM land exactly on their band's centre line until tempo spreads
/// them.
private struct EnergyScatter: View {
	let points: [LibraryStats.EnergyPoint]
	let timeBasis: EnergyTimeBasis

	/// Energy → band label, placed at each band's centre value so the
	/// continuous y-axis still reads in band terms.
	private static let bandTicks: [(value: Double, label: String)] = [
		(0.125, "Glacial"),
		(0.375, "Mellow"),
		(0.625, "Energetic"),
		(0.875, "Intense"),
	]

	private static func date(year: Int) -> Date {
		Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
	}

	/// Points plottable on the current axis. Every point has a release date;
	/// only library-dated songs have an added date, so the added view drops
	/// the rest rather than collapsing them onto a fake date.
	private var plotted: [LibraryStats.EnergyPoint] {
		timeBasis == .added ? points.filter { $0.addedDate != nil } : points
	}

	private func date(_ point: LibraryStats.EnergyPoint) -> Date {
		(timeBasis == .added ? point.addedDate : point.releaseDate) ?? point.releaseDate
	}

	/// X-axis bounds per basis. Release clamps to plausible era bounds
	/// (1900–2030) — without a domain Charts auto-ranges to the data, and a
	/// stray year-0 release date would drag the scale; the clamp clips it.
	/// Added range-frames to the library's own lifetime (system-set dates are
	/// reliable), so a years-old library fills the axis instead of hugging the
	/// right edge of a century-wide one.
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
				// Blend the band tints across the energy axis so a song
				// between two bands gets a mix — a smooth vertical gradient.
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
