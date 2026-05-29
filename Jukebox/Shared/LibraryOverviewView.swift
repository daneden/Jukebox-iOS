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
