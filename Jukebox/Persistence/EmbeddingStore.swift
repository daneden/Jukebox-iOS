//
//  EmbeddingStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Actor wrapper around the SwiftData container holding `SongEmbedding`
//  rows. Cache-first lookup for `AudioEmbeddingService` — repeat embeds
//  of the same song avoid the preview-download + AudioFeaturePrint
//  inference round-trip entirely.
//
//  Local-only (no CloudKit). Re-installing the app loses the cache and
//  the user pays ~5 minutes of background embedding the next time the
//  gem deck builds — acceptable for a once-per-device cost.

import Dispatch
import Foundation
import MusicKit
import SwiftData

actor EmbeddingStore {
	/// Bump when the embedding model changes (AudioFeaturePrint → CLAP, etc.).
	/// Old rows are treated as misses on read and overwritten on the next
	/// embed call.
	static let currentModelVersion = 1

	static let shared = EmbeddingStore()

	/// Pin the actor's executor to a single QoS. Callers span `.utility`
	/// (warm loop) and `.userInitiated` (dial walk); without pinning, the
	/// QoS of whichever task scheduled the running actor job determines
	/// what subsequent waiters see — and a higher-priority waiter behind a
	/// lower-priority job trips the runtime's priority-inversion warning.
	private nonisolated let queue = DispatchSerialQueue(
		label: "me.daneden.Jukebox.EmbeddingStore",
		qos: .userInitiated
	)
	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	private var container: ModelContainer?
	private var context: ModelContext?

	private func ensureLoaded() throws {
		if container != nil { return }
		let schema = Schema([SongEmbedding.self])
		// Named so this store gets its own sqlite file rather than
		// fighting `HistoryStore` and `TransitionFeedbackStore` over
		// the default unnamed `default.store`. Three actors opening
		// the same file with three different schemas leaves whichever
		// container initialised first holding the tables; the others
		// surface "no such table: ZSONGEMBEDDING" errors at fetch time.
		let config = ModelConfiguration("embeddings", schema: schema, cloudKitDatabase: .none)
		let c = try ModelContainer(for: schema, configurations: [config])
		container = c
		context = ModelContext(c)
	}

	func embedding(for songID: MusicItemID) -> [Float]? {
		do { try ensureLoaded() } catch { return nil }
		guard let context else { return nil }

		let id = songID.rawValue
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.songID == id && $0.modelVersion == version }
		)
		guard let stored = try? context.fetch(descriptor).first else { return nil }
		return Self.decode(stored.vector)
	}

	/// Bulk lookup — single SwiftData fetch for all matching rows. The walk
	/// uses this so it doesn't do N actor hops + N fetches to assemble the
	/// embedding dict it needs.
	func embeddings(for songIDs: [MusicItemID]) -> [MusicItemID: [Float]] {
		do { try ensureLoaded() } catch { return [:] }
		guard let context else { return [:] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [:] }

		var result: [MusicItemID: [Float]] = [:]
		result.reserveCapacity(rows.count)
		for row in rows {
			result[MusicItemID(row.songID)] = Self.decode(row.vector)
		}
		return result
	}

	func store(_ embedding: [Float], for songID: MusicItemID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let data = Self.encode(embedding)
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.songID == id }
		)
		if let existing = try? context.fetch(descriptor).first {
			existing.vector = data
			existing.modelVersion = Self.currentModelVersion
			existing.computedAt = Date()
		} else {
			let new = SongEmbedding(
				songID: id,
				vector: data,
				modelVersion: Self.currentModelVersion,
				computedAt: Date()
			)
			context.insert(new)
		}
		try? context.save()

		// Notify the toolbar progress tracker. No-op if this song isn't
		// in the current deck (e.g. ad-hoc embeds from the spike).
		Task { @MainActor in
			EmbeddingProgress.shared.recordProcessed(songID)
		}
	}

	/// Vector ↔ Data is raw little-endian Float32 bytes. iOS runs on
	/// little-endian hardware (Apple Silicon, all production ARM), so we
	/// don't bother with byte-swapping. If we ever need to migrate caches
	/// between platforms, bump `currentModelVersion`.
	private static func encode(_ floats: [Float]) -> Data {
		floats.withUnsafeBufferPointer { Data(buffer: $0) }
	}

	private static func decode(_ data: Data) -> [Float] {
		let count = data.count / MemoryLayout<Float>.size
		return data.withUnsafeBytes { ptr in
			Array(ptr.bindMemory(to: Float.self).prefix(count))
		}
	}
}
