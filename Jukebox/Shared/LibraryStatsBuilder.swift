//
//  LibraryStatsBuilder.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/05/2026.
//
//  Computes the LibraryOverviewView snapshot over the same analysis pool the
//  LibraryEmbeddingWarmer fills. Producer/consumer split so the overview never
//  blocks on MusicKit: `refresh()` classifies and persists to LibraryStatsStore;
//  the view paints the persisted snapshot instantly. We persist the small result
//  (counts + ≤1500 sampled points), not the heavy 10k-song union and vectors.
//

import Foundation
import MusicKit

struct LibraryStats: Codable {
	struct ProgressCounts: Equatable, Codable {
		let embedded: Int
		let total: Int
	}

	struct BucketCount: Identifiable, Equatable, Codable {
		let id: String
		let label: String
		let count: Int
	}

	struct DecadeCount: Identifiable, Equatable, Codable {
		let id: Int
		let decade: Int
		let count: Int
	}

	struct EnergyCount: Identifiable, Equatable, Codable {
		let id: Int
		let band: EnergyBand?
		let count: Int

		var label: String {
			band?.displayName ?? "Unclassified"
		}
	}

	/// A classified song on the energy-over-time scatter. Full dates, not years,
	/// so the temporal axis spreads songs across months rather than stacking them
	/// into yearly columns. `addedDate` is nil when the library add-date is
	/// missing, so the date-added view drops it. Songs with no cached BPM sit on
	/// their band's centre line and spread off it only as tempo is analysed.
	struct EnergyPoint: Identifiable, Equatable, Codable {
		let id: String
		let releaseDate: Date
		let addedDate: Date?
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
	/// Top N genres surfaced in the overview; past ~12 rows the table stops
	/// being scannable on a phone.
	static let topGenresLimit = 12

	/// Compute the snapshot from an already-fetched union + current cache state.
	/// Caller fetches the library size separately via `paginatedSongCount()`.
	static func stats(deck: LibraryStats.ProgressCounts, over union: [Song]) async -> LibraryStats {
		let ids = union.map(\.id)

		// One EmbeddingStore fetch yields both vectors and BPMs — they share rows;
		// two calls would serialize on the store's pinned executor and scan twice.
		async let embeddingBundle = EmbeddingStore.shared.embeddingsAndBPMs(for: ids)
		async let originalsLookup = OriginalReleaseStore.shared.originalDates(for: ids)
		async let genresLookup = GenreStore.shared.genres(for: ids)
		let (embeddings, bpms) = await embeddingBundle
		let originals = await originalsLookup
		let genres = await genresLookup

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

			if let band {
				energyCounts[band, default: 0] += 1
				if let date = originals[song.id] ?? song.releaseDate,
				   let energy = SongEnergy.value(band: band, bpm: bpms[song.id])
				{
					points.append(LibraryStats.EnergyPoint(
						id: song.id.rawValue,
						releaseDate: date,
						addedDate: song.libraryAddedDate,
						energy: energy,
						band: band
					))
				}
			} else {
				unclassifiedCount += 1
			}

			if let decade {
				decadeCounts[decade, default: 0] += 1
			}

			// Apple's slash-combined tokens are kept atomic (see
			// GenreSimilarity.swift) — splitting them merges genres Apple groups.
			// From the genre cache, not `song.genreNames` (always empty on library).
			for raw in songGenres {
				let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmed.isEmpty {
					genreCounts[trimmed, default: 0] += 1
				}
			}
		}

		// Band order matches the energy chips (glacial → intense). Unclassified
		// gets a sentinel `id` past the band range so SwiftUI's diffing keeps it
		// pinned at the bottom.
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

		// Cap scatter points so the chart stays cheap on a large library;
		// `classifiedCount` keeps the true placeable total for the footer.
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

	enum RefreshOutcome {
		/// A fresh snapshot was computed and persisted.
		case computed(LibraryStats)
		/// Another refresh is already in flight; read its result from the store.
		case coalesced
		/// The union fetch failed (e.g. offline) — nothing was computed.
		case failed
	}

	/// Recompute the whole-library stats over the memoized union and persist the
	/// snapshot. Coalesced — concurrent callers collapse to one in-flight pass;
	/// losers get `.coalesced` and read the winner's write. Reuses the warmer's
	/// memoized union so back-to-back refreshes don't each re-fetch 10k Songs.
	@discardableResult
	static func refresh() async -> RefreshOutcome {
		guard await RefreshGate.shared.begin() else { return .coalesced }

		let outcome: RefreshOutcome
		if let union = try? await LibraryEmbeddingWarmer.shared.librarySnapshot() {
			let fresh = await stats(deck: deckCounts(), over: union)
			await LibraryStatsStore.shared.save(fresh)
			outcome = .computed(fresh)
		} else {
			outcome = .failed
		}

		await RefreshGate.shared.end()
		return outcome
	}

	/// Cheap "has analysis advanced?" fingerprint: deck progress plus COUNT(*) of
	/// embedded and genre-resolved rows. When unchanged between ticks the sheet
	/// skips the full reclassify, so an idle open sheet doesn't burn the energy gauge.
	static func coverageSignature() async -> [Int] {
		async let embedded = EmbeddingStore.shared.totalEmbeddedCount()
		async let genres = GenreStore.shared.totalResolvedCount()
		let deck = await deckCounts()
		return [deck.embedded, deck.total, await embedded, await genres]
	}

	/// Current deck embedding progress, read on the MainActor where
	/// `EmbeddingProgress` lives.
	private static func deckCounts() async -> LibraryStats.ProgressCounts {
		await MainActor.run {
			LibraryStats.ProgressCounts(
				embedded: EmbeddingProgress.shared.embeddedCount,
				total: EmbeddingProgress.shared.totalCount
			)
		}
	}

	/// Total song count via paginated `MusicLibraryRequest<Song>`. Retains only
	/// the running count — holding 50k Song values just to discard them would
	/// defeat the lightweight intent. Returns nil on failure so the view degrades
	/// to "Library size unavailable" rather than breaking the sheet.
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

/// Coalesces concurrent `LibraryStatsBuilder.refresh()` calls so they don't
/// stack multiple union-fetch + 10k-song reclassify passes at once.
private actor RefreshGate {
	static let shared = RefreshGate()
	private var running = false

	/// True if the caller acquired the gate; false if a refresh is already in
	/// flight (the loser bails and reads the winner's snapshot).
	func begin() -> Bool {
		if running { return false }
		running = true
		return true
	}

	func end() {
		running = false
	}
}
