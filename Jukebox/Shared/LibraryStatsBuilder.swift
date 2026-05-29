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
//  Producer/consumer split — the overview never blocks on MusicKit:
//   - `refresh()` (producer) fetches the warmer's memoized 3-pool union,
//     classifies, and persists the result to `LibraryStatsStore`. Coalesced
//     so the eager prime + the sheet's revalidate don't stack. Triggered
//     eagerly when the toolbar indicator appears and on a coverage-gated tick
//     while the sheet is open.
//   - The view (consumer) paints the persisted snapshot instantly, then shows
//     `refresh()`'s result as it lands. First-ever open pays one compute; the
//     eager prime usually beats the user to it.
//   - `paginatedSongCount()` — total library count via 1000-per-batch
//     pagination, run in parallel for the size cell only.
//
//  We persist the small computed *result* (a few hundred counts + ≤1500
//  sampled points), not the heavy *inputs* (the 10k-song union, the vectors)
//  — a different, cheaper trade than the previously-rejected union cache.
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

	/// A classified song placed in the energy-over-time scatter: continuous
	/// energy (0–1) against either its release date or the date it was added
	/// to the library, colored by band. Full dates, not years — the scatter
	/// plots them on a temporal axis so songs spread across months rather than
	/// stacking into yearly columns. Only songs we can place (energy non-nil,
	/// with a release date) appear; `addedDate` is nil when the library
	/// add-date is missing, so the date-added view drops it. Sampled to a cap
	/// so the chart stays cheap. Songs with no cached BPM sit exactly on their
	/// band's centre line and spread off it only as tempo is analyzed.
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
	/// Top N genres surfaced in the overview. The tail is summarised as
	/// "+ N more" in the view rather than listed — past ~12 rows the
	/// table stops being scannable on a phone.
	static let topGenresLimit = 12

	/// Compute the snapshot from an already-fetched union + the *current*
	/// cache state — store reads + in-memory tallies, cheap enough to run
	/// on a refresh timer while the sheet is open. Caller fetches the
	/// library size separately via `paginatedSongCount()`.
	static func stats(deck: LibraryStats.ProgressCounts, over union: [Song]) async -> LibraryStats {
		let ids = union.map(\.id)

		// One EmbeddingStore fetch yields both vectors and BPMs — they live on
		// the same rows, and two separate calls would serialize on the store's
		// pinned executor and scan the table twice. Genres + originals are
		// separate actors, so they run concurrently with it via async let.
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

			// Energy: count the band, and place classified songs on the
			// scatter (release year × continuous energy). Songs with no BPM
			// sit at their band centre; BPM spreads them.
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

	enum RefreshOutcome {
		/// A fresh snapshot was computed and persisted.
		case computed(LibraryStats)
		/// Another refresh is already in flight; read its result from the store.
		case coalesced
		/// The union fetch failed (e.g. offline) — nothing was computed.
		case failed
	}

	/// Recompute the whole-library stats over the (memoized) union and persist
	/// the snapshot. The overview reads the persisted result for an instant
	/// first paint; this keeps it current. Coalesced — concurrent callers (the
	/// eager prime on indicator-appear, the sheet's background revalidate, a
	/// refresh tick) collapse to one in-flight pass; losers get `.coalesced`
	/// and read the winner's write. Reuses the warmer's memoized union, so
	/// back-to-back refreshes don't each re-fetch 10k Songs from MusicKit.
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

	/// Cheap "has analysis advanced?" fingerprint for the overview's refresh
	/// gate: deck progress plus COUNT(*) of embedded and genre-resolved rows.
	/// All counts, no row materialization — when the tuple is unchanged between
	/// ticks the sheet skips the full reclassify, so an idle open sheet doesn't
	/// burn the energy gauge.
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

/// Coalesces concurrent `LibraryStatsBuilder.refresh()` calls so the eager
/// prime, the sheet's background revalidate, and the refresh ticks don't stack
/// multiple union-fetch + 10k-song reclassify passes at once.
private actor RefreshGate {
	static let shared = RefreshGate()
	private var running = false

	/// True if the caller acquired the gate and should run; false if a refresh
	/// is already in flight (the loser bails and reads the winner's snapshot).
	func begin() -> Bool {
		if running { return false }
		running = true
		return true
	}

	func end() {
		running = false
	}
}
