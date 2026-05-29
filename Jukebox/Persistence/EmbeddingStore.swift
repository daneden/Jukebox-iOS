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

	/// Bump when `BPMDetector`'s algorithm changes. Independent of
	/// `currentModelVersion` so an improved detector re-runs over existing
	/// rows *without* invalidating the cached embedding vector. BPM reads
	/// deliberately do NOT gate on this — they keep serving the old value
	/// until the warmer's re-detect pass (driven by `staleBPMIDs`)
	/// overwrites it, so there's no coverage blackout while it catches up.
	static let currentBPMModelVersion = 1

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
		let schema = Schema([SongEmbedding.self, EmbeddingFailure.self])
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
			// Only overwrite BPM when we have a fresh value — otherwise
			// preserve whatever was already cached. This keeps a known-
			// good BPM from a previous embed pass from being wiped if
			// the next pass's detector returns nil (e.g. transient
			// inference flakiness).
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

		// Notify the toolbar progress tracker. No-op if this song isn't
		// in the current deck (e.g. ad-hoc embeds from the spike).
		Task { @MainActor in
			EmbeddingProgress.shared.recordProcessed(songID)
		}
	}

	/// Whether the row for `songID` has a non-nil BPM. The library
	/// warmer uses this to decide between "compute embedding + BPM"
	/// (no row yet) and "BPM-only refresh" (row exists, BPM nil) —
	/// without it we'd either re-download for the full embed pipeline
	/// every time, or never backfill BPM on legacy rows.
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

	/// Update only the BPM fields on an existing row. Used by the
	/// library warmer when backfilling BPM for a song whose embedding
	/// was previously cached without it (e.g. processed by the
	/// foreground deck warm, which skips BPM detection to stay quick).
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

	/// Re-detect outcome for a stale-version row. Always stamps the row to
	/// the current BPM version (we've now evaluated it with the current
	/// detector), so `staleBPMIDs` stops surfacing it and the warmer
	/// doesn't re-download it every pass. A non-nil result overwrites the
	/// BPM; a nil result (the new detector also gave up) keeps the old
	/// value rather than wiping a usable-if-imperfect one.
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

	/// Bulk BPM lookup. Mirrors `embeddings(for:)` — single SwiftData
	/// fetch for all matching rows. Returns only songs that have a
	/// non-nil BPM cached; the walk uses this to decide whether to
	/// include a BPM-similarity term for each candidate pair.
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

	/// Song IDs with a cached embedding and a non-nil BPM detected by an
	/// *older* `BPMDetector` version. The warmer re-runs these through the
	/// current detector (re-downloading the preview, no re-embed) and
	/// overwrites in place. Excludes `bpm == nil` — the old detector gave
	/// up on those, and re-running won't recover them without also
	/// re-downloading the genuinely-ambient long tail.
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

	/// Bulk lookup of embeddings AND BPMs in a SINGLE fetch over the same
	/// rows. The overview's stats pass needs both maps over the same id set;
	/// calling `embeddings(for:)` then `bpms(for:)` runs two full scans of the
	/// identical rows, serialized on this actor's pinned executor (async let
	/// can't parallelize two methods on one pinned actor). One fetch, both maps.
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

	/// COUNT(*) of current-version embedding rows — a cheap freshness signal
	/// for the overview's refresh gate (no row materialization, no vector
	/// decode). Grows as the warmer embeds the long tail; an unchanged count
	/// between ticks means analysis hasn't advanced, so a recompute is skipped.
	func totalEmbeddedCount() -> Int {
		do { try ensureLoaded() } catch { return 0 }
		guard let context else { return 0 }

		let version = Self.currentModelVersion
		let descriptor = FetchDescriptor<SongEmbedding>(
			predicate: #Predicate { $0.modelVersion == version }
		)
		return (try? context.fetchCount(descriptor)) ?? 0
	}

	/// Mark a song as having permanently failed to embed. Subsequent
	/// `recentFailures` queries within the retry window will include
	/// this song, so the library warmer skips it. A successful embed
	/// later (or another failure) overwrites the row in place.
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

	/// Song IDs that failed permanently within the last `window` seconds.
	/// Used by the library warmer to skip songs we know we can't embed
	/// yet — without this they'd be retried on every warm pass forever.
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
