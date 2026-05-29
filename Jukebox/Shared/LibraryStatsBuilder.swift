//
//  LibraryStatsBuilder.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/05/2026.
//
//  Computes the LibraryOverviewView snapshot: deck + library embedding
//  progress, total library size, and three categorical distributions
//  (energy band, release decade, top genres) over the same analysis
//  pool the LibraryEmbeddingWarmer is filling.
//
//  Two parallel queries:
//   - `LibraryEmbeddingWarmer.shared.librarySnapshot()` — three-pool
//     union of up to 10k songs, mirrors what the warmer will embed.
//     Drives every distribution.
//   - `paginatedSongCount()` — total library count via 1000-per-batch
//     pagination. The view shows union-backed sections as soon as the
//     union returns and updates the size cell when its count lands.
//
//  Snapshot only — recomputed each time the sheet opens. No persistent
//  cache (the union takes ~1–2s on Wi-Fi for a populated library; this
//  is rare enough that a 1-day cache wouldn't pay off).
//

import Foundation
import MusicKit

struct LibraryStats {
	struct ProgressCounts: Equatable {
		let embedded: Int
		let total: Int
	}

	struct BucketCount: Identifiable, Equatable {
		let id: String
		let label: String
		let count: Int
	}

	struct DecadeCount: Identifiable, Equatable {
		let id: Int
		let decade: Int
		let count: Int
	}

	struct EnergyCount: Identifiable, Equatable {
		let id: Int
		let band: EnergyBand?
		let count: Int

		var label: String {
			band?.displayName ?? "Unclassified"
		}
	}

	/// A classified song placed in the energy-over-time scatter: continuous
	/// energy (0–1) against either its release year or the year it was added
	/// to the library, colored by band. Only songs we can place (energy
	/// non-nil, with a release date) appear; `addedYear` is nil when the
	/// library add-date is missing, so the date-added view drops it. Sampled
	/// to a cap so the chart stays cheap. Songs with no cached BPM sit exactly
	/// on their band's centre line and spread off it only as tempo is analyzed.
	struct EnergyPoint: Identifiable, Equatable {
		let id: String
		let year: Int
		let addedYear: Int?
		let energy: Double
		let band: EnergyBand
	}

	let deck: ProgressCounts
	let analysisPool: ProgressCounts
	let energyBuckets: [EnergyCount]
	let decadeHistogram: [DecadeCount]
	let energyPoints: [EnergyPoint]
	/// Songs that could be placed on the scatter (before the sample cap).
	let classifiedCount: Int
	let topGenres: [BucketCount]
	let totalGenreCount: Int
}

enum LibraryStatsBuilder {
	/// Top N genres surfaced in the overview. The tail is summarised as
	/// "+ N more" in the view rather than listed — past ~12 rows the
	/// table stops being scannable on a phone.
	static let topGenresLimit = 12

	/// The 3-pool union the warmer fills — the slow, MusicKit-bound step.
	/// Fetch it once; the view refreshes by re-running `stats(deck:over:)`
	/// over the same songs as the caches warm (no MusicKit re-fetch).
	static func librarySnapshot() async throws -> [Song] {
		try await LibraryEmbeddingWarmer.shared.librarySnapshot()
	}

	/// Compute the snapshot from an already-fetched union + the *current*
	/// cache state — store reads + in-memory tallies, cheap enough to run
	/// on a refresh timer while the sheet is open. Caller fetches the
	/// library size separately via `paginatedSongCount()`.
	static func stats(deck: LibraryStats.ProgressCounts, over union: [Song]) async -> LibraryStats {
		let ids = union.map(\.id)

		async let embeddingsLookup = EmbeddingStore.shared.embeddings(for: ids)
		async let originalsLookup = OriginalReleaseStore.shared.originalDates(for: ids)
		async let genresLookup = GenreStore.shared.genres(for: ids)
		async let bpmsLookup = EmbeddingStore.shared.bpms(for: ids)
		let embeddings = await embeddingsLookup
		let originals = await originalsLookup
		let genres = await genresLookup
		let bpms = await bpmsLookup

		let bundle = EnergyCentroidsLoader.bundled
		let flat = bundle.map(EnergyClassifier.flatten(bundle:)) ?? []

		var energyCounts: [EnergyBand: Int] = [:]
		var unclassifiedCount = 0
		var decadeCounts: [Int: Int] = [:]
		var points: [LibraryStats.EnergyPoint] = []
		var genreCounts: [String: Int] = [:]

		for song in union {
			let songGenres = genres[song.id] ?? []

			let band: EnergyBand? = bundle.flatMap {
				EnergyClassifier.band(
					embedding: embeddings[song.id],
					genres: songGenres,
					bundle: $0,
					flat: flat
				)
			}
			let decade = song.releaseDecade(override: originals[song.id])

			// Energy: count the band, and place classified songs on the
			// scatter (release year × continuous energy). Songs with no BPM
			// sit at their band centre; BPM spreads them.
			if let band {
				energyCounts[band, default: 0] += 1
				if let date = originals[song.id] ?? song.releaseDate,
				   let energy = SongEnergy.value(band: band, bpm: bpms[song.id])
				{
					let addedYear = song.libraryAddedDate.map {
						Calendar.current.component(.year, from: $0)
					}
					points.append(LibraryStats.EnergyPoint(
						id: song.id.rawValue,
						year: Calendar.current.component(.year, from: date),
						addedYear: addedYear,
						energy: energy,
						band: band
					))
				}
			} else {
				unclassifiedCount += 1
			}

			// Decade
			if let decade {
				decadeCounts[decade, default: 0] += 1
			}

			// Genre (Apple's slash-combined tokens are kept atomic — see
			// GenreSimilarity.swift; splitting them merges unrelated genres
			// together that Apple deliberately groups). Sourced from the
			// genre cache, not `song.genreNames` — the latter is always
			// empty on library songs.
			for raw in songGenres {
				let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmed.isEmpty {
					genreCounts[trimmed, default: 0] += 1
				}
			}
		}

		// Band order so the table reads the same as the energy chips
		// (glacial → intense). Unclassified is tagged with a stable
		// sentinel `id` past the band range so SwiftUI's diffing keeps
		// it pinned at the bottom of the list.
		var energyRows: [LibraryStats.EnergyCount] = []
		for band in EnergyBand.allCases where band != .any {
			energyRows.append(LibraryStats.EnergyCount(
				id: band.rawValue,
				band: band,
				count: energyCounts[band, default: 0]
			))
		}
		energyRows.append(LibraryStats.EnergyCount(id: 99, band: nil, count: unclassifiedCount))

		var decades: [LibraryStats.DecadeCount] = []
		for (decade, count) in decadeCounts {
			decades.append(LibraryStats.DecadeCount(id: decade, decade: decade, count: count))
		}
		decades.sort { $0.decade < $1.decade }

		// Sample the scatter points to a cap so the chart stays cheap on a
		// large, fully-warmed library. `classifiedCount` keeps the true
		// placeable total for the footer even when fewer dots are drawn.
		let sampleCap = 1500
		let energyPoints: [LibraryStats.EnergyPoint]
		if points.count > sampleCap {
			let step = Double(points.count) / Double(sampleCap)
			energyPoints = (0 ..< sampleCap).map { points[Int(Double($0) * step)] }
		} else {
			energyPoints = points
		}

		var sortedGenres: [LibraryStats.BucketCount] = []
		for (name, count) in genreCounts {
			sortedGenres.append(LibraryStats.BucketCount(id: name, label: name, count: count))
		}
		sortedGenres.sort { lhs, rhs in
			lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
		}
		let topGenres = Array(sortedGenres.prefix(topGenresLimit))

		let embeddedInPool = embeddings.count

		return LibraryStats(
			deck: deck,
			analysisPool: .init(embedded: embeddedInPool, total: union.count),
			energyBuckets: energyRows,
			decadeHistogram: decades,
			energyPoints: energyPoints,
			classifiedCount: points.count,
			topGenres: topGenres,
			totalGenreCount: genreCounts.count
		)
	}

	/// Total song count via paginated `MusicLibraryRequest<Song>`. We
	/// page through 1000 at a time and only retain the running count —
	/// holding 50k Song values just to discard them would defeat the
	/// "lightweight in parallel with the union" intent.
	///
	/// Returns nil on failure rather than throwing — the view degrades
	/// gracefully to "Library size unavailable" instead of breaking the
	/// rest of the sheet.
	static func paginatedSongCount() async -> Int? {
		var request = MusicLibraryRequest<Song>()
		request.limit = 1000
		do {
			var current = try await request.response().items
			var count = current.count
			while current.hasNextBatch {
				guard let next = try await current.nextBatch() else { break }
				count += next.count
				current = next
			}
			return count
		} catch {
			return nil
		}
	}
}
