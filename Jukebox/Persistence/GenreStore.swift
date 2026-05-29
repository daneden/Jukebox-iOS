//
//  GenreStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Actor wrapper around the SwiftData container holding `SongGenres`
//  rows — cached genre names per library song, since bare library
//  requests leave the `.genres` relationship empty. Hydrated by
//  `LibraryEmbeddingWarmer`. Local-only (no CloudKit); reinstall loses
//  the cache.

import Dispatch
import Foundation
import MusicKit
import SwiftData

actor GenreStore {
	/// Bump when the hydration strategy changes. Old rows are treated as misses.
	static let currentModelVersion = 1

	static let shared = GenreStore()

	/// Pinned `userInitiated` executor, like the other per-song stores:
	/// userInitiated readers and the utility warmer both touch the actor,
	/// and without pinning the runtime flags priority inversions.
	private nonisolated let queue = DispatchSerialQueue(
		label: "me.daneden.Jukebox.GenreStore",
		qos: .userInitiated
	)
	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([SongGenres.self])
		// Named so this store gets its own sqlite file rather than
		// fighting the other stores over the default unnamed store.
		let config = ModelConfiguration("genres", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	/// Bulk lookup, single fetch. Returns only songs with a non-empty cached
	/// genre list; callers treat a missing key as "no genre signal".
	func genres(for songIDs: [MusicItemID]) -> [MusicItemID: [String]] {
		do { try ensureLoaded() } catch { return [:] }
		guard let context else { return [:] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongGenres>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [:] }

		var result: [MusicItemID: [String]] = [:]
		result.reserveCapacity(rows.count)
		for row in rows where !row.genreNames.isEmpty {
			result[MusicItemID(row.songID)] = row.genreNames
		}
		return result
	}

	/// "Already hydrated?" lookup for the warmer. Includes empty-`genreNames`
	/// rows — recording the resolution avoids re-hydrating genuinely-genreless songs.
	func resolvedIDs(for songIDs: [MusicItemID]) -> Set<String> {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongGenres>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [] }
		return Set(rows.map(\.songID))
	}

	/// COUNT(*) of current-version rows — a cheap freshness signal for the
	/// overview's refresh gate. Pairs with `EmbeddingStore.totalEmbeddedCount()`
	/// so an idle sheet doesn't re-classify the whole pool every tick.
	func totalResolvedCount() -> Int {
		do { try ensureLoaded() } catch { return 0 }
		guard let context else { return 0 }

		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongGenres>(
			predicate: #Predicate { $0.modelVersion == version }
		)
		return (try? context.fetchCount(descriptor)) ?? 0
	}

	/// Upsert. Pass an empty array when the song genuinely has no genres —
	/// recording the resolution stops the warmer from re-hydrating it.
	func store(_ names: [String], for songID: MusicItemID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let descriptor = FetchDescriptor<SongGenres>(
			predicate: #Predicate { $0.songID == id }
		)
		if let existing = try? context.fetch(descriptor).first {
			existing.genreNames = names
			existing.modelVersion = Self.currentModelVersion
			existing.resolvedAt = Date()
		} else {
			let new = SongGenres(
				songID: id,
				genreNames: names,
				modelVersion: Self.currentModelVersion,
				resolvedAt: Date()
			)
			context.insert(new)
		}
		try? context.save()
	}
}
