//
//  EmbeddingStore.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Actor wrapper around the SwiftData container holding `SongEmbedding`
//  rows. Cache-first lookup for `AudioEmbeddingService` — repeat embeds
//  avoid the preview-download + AudioFeaturePrint inference round-trip.
//  Local-only (no CloudKit); reinstall loses the cache.

import Dispatch
import Foundation
import MusicKit
import SwiftData

actor EmbeddingStore {
	/// Bump when the embedding model changes (AudioFeaturePrint → CLAP, etc.).
	/// Old rows are treated as misses and overwritten on the next embed.
	static let currentModelVersion = 1

	/// Bump when `BPMDetector`'s algorithm changes. Independent of
	/// `currentModelVersion` so an improved detector re-runs without
	/// invalidating the cached embedding vector. BPM reads deliberately do
	/// NOT gate on this — they keep serving the old value until the warmer's
	/// re-detect pass (`staleBPMIDs`) overwrites it, so no coverage blackout.
	static let currentBPMModelVersion = 1

	static let shared = EmbeddingStore()

	/// Pin the actor's executor to a single QoS. Callers span `.utility`
	/// (warm loop) and `.userInitiated` (dial walk); without pinning, a
	/// higher-priority waiter behind a lower-priority job trips the runtime's
	/// priority-inversion warning.
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
		let schema = Schema([SongEmbedding.self, EmbeddingFailure.self])
		// Named so this store gets its own sqlite file. Multiple actors
		// opening the default unnamed store with different schemas leaves
		// whichever initialised first holding the tables; the rest surface
		// "no such table: ZSONGEMBEDDING" at fetch time.
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

	/// Bulk lookup in a single fetch — avoids N actor hops + N fetches.
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

	func store(
		_ embedding: [Float],
		bpm: Double? = nil,
		bpmConfidence: Float? = nil,
		for songID: MusicItemID
	) {
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
			// Only overwrite BPM when we have a fresh value, so a nil from
			// transient inference flakiness can't wipe a known-good BPM.
			if let bpm {
				existing.bpm = bpm
				existing.bpmConfidence = bpmConfidence
				existing.bpmModelVersion = Self.currentBPMModelVersion
			}
		} else {
			let new = SongEmbedding(
				songID: id,
				vector: data,
				modelVersion: Self.currentModelVersion,
				computedAt: Date(),
				bpm: bpm,
				bpmConfidence: bpmConfidence,
				bpmModelVersion: bpm != nil ? Self.currentBPMModelVersion : 0
			)
			context.insert(new)
		}
		try? context.save()

		// Notify the toolbar progress tracker (no-op if not in the deck).
		Task { @MainActor in
			EmbeddingProgress.shared.recordProcessed(songID)
		}
	}

	/// Whether the row for `songID` has a non-nil BPM. Lets the warmer
	/// choose "compute embedding + BPM" (no row) vs "BPM-only refresh"
	/// (row exists, BPM nil) instead of re-running the full pipeline.
	func hasBPM(for songID: MusicItemID) -> Bool {
		do { try ensureLoaded() } catch { return false }
		guard let context else { return false }

		let id = songID.rawValue
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.songID == id && $0.modelVersion == version }
		)
		guard let row = try? context.fetch(descriptor).first else { return false }
		return row.bpm != nil
	}

	/// Update only the BPM fields on an existing row. Backfills BPM for a
	/// song embedded without it (the foreground deck warm skips BPM to stay quick).
	func updateBPM(bpm: Double, bpmConfidence: Float, for songID: MusicItemID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.songID == id }
		)
		guard let existing = try? context.fetch(descriptor).first else { return }
		existing.bpm = bpm
		existing.bpmConfidence = bpmConfidence
		existing.bpmModelVersion = Self.currentBPMModelVersion
		try? context.save()
	}

	/// Re-detect outcome for a stale-version row. Always stamps the current
	/// BPM version so `staleBPMIDs` stops surfacing it. A non-nil result
	/// overwrites; a nil result keeps the old value rather than wiping it.
	func refreshBPM(bpm: Double?, bpmConfidence: Float?, for songID: MusicItemID) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.songID == id }
		)
		guard let existing = try? context.fetch(descriptor).first else { return }
		if let bpm {
			existing.bpm = bpm
			existing.bpmConfidence = bpmConfidence
		}
		existing.bpmModelVersion = Self.currentBPMModelVersion
		try? context.save()
	}

	/// Bulk BPM lookup, single fetch. Returns only songs with a non-nil
	/// BPM cached.
	func bpms(for songIDs: [MusicItemID]) -> [MusicItemID: Double] {
		do { try ensureLoaded() } catch { return [:] }
		guard let context else { return [:] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return [:] }

		var result: [MusicItemID: Double] = [:]
		result.reserveCapacity(rows.count)
		for row in rows {
			if let bpm = row.bpm {
				result[MusicItemID(row.songID)] = bpm
			}
		}
		return result
	}

	/// Song IDs with a cached embedding and a non-nil BPM from an *older*
	/// `BPMDetector` version, for the warmer to re-run. Excludes `bpm == nil`:
	/// the old detector gave up on those and re-running won't recover them
	/// without re-downloading the genuinely-ambient long tail.
	func staleBPMIDs(for songIDs: [MusicItemID]) -> Set<String> {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let bpmVersion = Self.currentBPMModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate {
				rawIDs.contains($0.songID)
					&& $0.modelVersion == version
					&& $0.bpm != nil
					&& $0.bpmModelVersion < bpmVersion
			}
		)
		guard let rows = try? context.fetch(descriptor) else { return [] }
		return Set(rows.map(\.songID))
	}

	/// Both maps in a SINGLE fetch over the same rows. Calling
	/// `embeddings(for:)` then `bpms(for:)` scans the identical rows twice,
	/// serialized on this pinned executor (async let can't parallelize two
	/// methods on one pinned actor).
	func embeddingsAndBPMs(
		for songIDs: [MusicItemID]
	) -> (embeddings: [MusicItemID: [Float]], bpms: [MusicItemID: Double]) {
		do { try ensureLoaded() } catch { return ([:], [:]) }
		guard let context else { return ([:], [:]) }

		let rawIDs = Set(songIDs.map(\.rawValue))
		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { rawIDs.contains($0.songID) && $0.modelVersion == version }
		)
		guard let rows = try? context.fetch(descriptor) else { return ([:], [:]) }

		var embeddings: [MusicItemID: [Float]] = [:]
		var bpms: [MusicItemID: Double] = [:]
		embeddings.reserveCapacity(rows.count)
		for row in rows {
			let id = MusicItemID(row.songID)
			embeddings[id] = Self.decode(row.vector)
			if let bpm = row.bpm {
				bpms[id] = bpm
			}
		}
		return (embeddings, bpms)
	}

	/// COUNT(*) of current-version rows — a cheap freshness signal for the
	/// overview's refresh gate. An unchanged count between ticks means
	/// analysis hasn't advanced, so a recompute is skipped.
	func totalEmbeddedCount() -> Int {
		do { try ensureLoaded() } catch { return 0 }
		guard let context else { return 0 }

		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.modelVersion == version }
		)
		return (try? context.fetchCount(descriptor)) ?? 0
	}

	/// Mark a song as permanently failed to embed, so `recentFailures`
	/// surfaces it within the retry window and the warmer skips it. A later
	/// embed (or another failure) overwrites the row in place.
	func recordFailure(songID: MusicItemID, reason: String) {
		do { try ensureLoaded() } catch { return }
		guard let context else { return }

		let id = songID.rawValue
		let descriptor = FetchDescriptor<EmbeddingFailure>(
			predicate: #Predicate { $0.songID == id }
		)
		if let existing = try? context.fetch(descriptor).first {
			existing.failedAt = Date()
			existing.reason = reason
		} else {
			context.insert(EmbeddingFailure(songID: id, failedAt: Date(), reason: reason))
		}
		try? context.save()
	}

	/// Song IDs that failed permanently within the last `window` seconds, so
	/// the warmer skips them instead of retrying on every pass forever.
	func recentFailures(within window: TimeInterval) -> Set<String> {
		do { try ensureLoaded() } catch { return [] }
		guard let context else { return [] }

		let cutoff = Date(timeIntervalSinceNow: -window)
		let descriptor = FetchDescriptor<EmbeddingFailure>(
			predicate: #Predicate { $0.failedAt > cutoff }
		)
		guard let rows = try? context.fetch(descriptor) else { return [] }
		return Set(rows.map(\.songID))
	}

	/// Raw little-endian Float32 bytes, no byte-swapping — iOS is always
	/// little-endian. To migrate caches across platforms, bump `currentModelVersion`.
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
