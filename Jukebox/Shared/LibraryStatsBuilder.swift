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

	let deck: ProgressCounts
	let analysisPool: ProgressCounts
	let energyBuckets: [EnergyCount]
	let decadeHistogram: [DecadeCount]
	let topGenres: [BucketCount]
	let totalGenreCount: Int
}

enum LibraryStatsBuilder {
	/// Top N genres surfaced in the overview. The tail is summarised as
	/// "+ N more" in the view rather than listed — past ~12 rows the
	/// table stops being scannable on a phone.
	static let topGenresLimit = 12

	/// Build the union-backed stats. Caller is responsible for parallel
	/// fetching the library size via `paginatedSongCount()` if it wants
	/// the size cell to surface too.
	static func buildPoolStats(deck: LibraryStats.ProgressCounts) async throws -> LibraryStats {
		let union = try await LibraryEmbeddingWarmer.shared.librarySnapshot()
		let ids = union.map(\.id)

		async let embeddingsLookup = EmbeddingStore.shared.embeddings(for: ids)
		async let originalsLookup = OriginalReleaseStore.shared.originalDates(for: ids)
		let embeddings = await embeddingsLookup
		let originals = await originalsLookup

		let bundle = EnergyCentroidsLoader.bundled
		let flat = bundle.map(EnergyClassifier.flatten(bundle:)) ?? []

		var energyCounts: [EnergyBand: Int] = [:]
		var unclassifiedCount = 0
		var decadeCounts: [Int: Int] = [:]
		var genreCounts: [String: Int] = [:]

		for song in union {
			// Energy
			if let bundle {
				if let band = EnergyClassifier.band(
					for: song,
					embedding: embeddings[song.id],
					bundle: bundle,
					flat: flat
				) {
					energyCounts[band, default: 0] += 1
				} else {
					unclassifiedCount += 1
				}
			} else {
				unclassifiedCount += 1
			}

			// Decade
			if let decade = song.releaseDecade(override: originals[song.id]) {
				decadeCounts[decade, default: 0] += 1
			}

			// Genre (Apple's slash-combined tokens are kept atomic — see
			// GenreSimilarity.swift; splitting them merges unrelated genres
			// together that Apple deliberately groups).
			for raw in song.genreNames {
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
