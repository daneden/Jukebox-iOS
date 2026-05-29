//
//  LibraryEmbeddingWarmer.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Long-tail audio-embedding warmer: embeds everything beyond the active
//  300-song deck (capped at ~10k library songs by play-count and add
//  date) so future decks start on real sonic similarity instead of the
//  walk's metadata-only fallback.
//
//  Gating is checked at entry and between each song. WiFi is always
//  required (a full pass is ~5GB). Background passes require external
//  power; foreground passes run on battery but defer to Low Power Mode.
//  See `conditionsFavorable(requirePower:)`.
//

import Foundation
import MusicKit
import Network
import os
#if os(iOS)
	import BackgroundTasks
	import UIKit
#endif

actor LibraryEmbeddingWarmer {
	static let shared = LibraryEmbeddingWarmer()

	/// Hard cap on songs embedded beyond the active deck. Keeps bandwidth +
	/// storage bounded (a 50k library all-in is ~25GB) while covering the
	/// songs most likely to influence future decks.
	static let libraryCap = 10000

	/// Per-pool fetch ceiling. Set so the deduped union can still reach
	/// `libraryCap` even when pools overlap heavily.
	static let perPoolFetch = 5000

	/// Sleep between songs in the warm loop. Gentle cadence — nobody's
	/// waiting for the long tail, and it's friendlier on battery + the CDN.
	static let breath: Duration = .milliseconds(500)

	/// Sleep between songs in the genre-hydration loop. Shorter than
	/// `breath` — `.with([.genres])` is a lightweight fetch, no audio.
	static let genreBreath: Duration = .milliseconds(80)

	/// How long a permanently-failed song stays negative-cached before one
	/// retry — Apple's catalog occasionally backfills previews for old items.
	static let failureRetryAfter: TimeInterval = 60 * 86400

	#if os(iOS)
		/// Must match `Info.plist` → `BGTaskSchedulerPermittedIdentifiers`.
		static let bgTaskIdentifier = "me.daneden.Jukebox.libraryEmbedding"

		/// Earliest re-fire delay (a scheduler hint, not a guarantee). 4h
		/// keeps us out of the system's "hungry app" doghouse while still
		/// giving multiple chances per day.
		static let bgTaskRefireDelay: TimeInterval = 4 * 60 * 60
	#endif

	private var isRunning = false

	/// Session cache of the three-pool union. Membership is stable as the
	/// caches warm (only per-song metadata changes), so repeat callers in a
	/// short window share one fetch instead of each re-paginating up to 10k
	/// Songs from MusicKit.
	private var cachedUnion: (songs: [Song], at: Date)?

	/// How long a cached union stays fresh. Bounded so library mutations
	/// (newly added / played songs shifting the pool sorts) surface within
	/// a session without refetching on every call.
	static let unionCacheTTL: TimeInterval = 120

	// Cached gating state, updated by background callbacks. Kept in a lock
	// so `conditionsFavorable` can be a synchronous nonisolated read in
	// the warm loop's hot path.
	private nonisolated let pathMonitor = NWPathMonitor()
	private nonisolated let pathMonitorQueue = DispatchQueue(
		label: "me.daneden.Jukebox.LibraryEmbeddingWarmer.path"
	)
	private nonisolated let _pathSatisfied = OSAllocatedUnfairLock<Bool>(initialState: false)
	// Defaults to true so macOS (no battery observation) reads as "powered."
	private nonisolated let _externalPowerConnected = OSAllocatedUnfairLock<Bool>(initialState: true)
	private nonisolated let _monitoringStarted = OSAllocatedUnfairLock<Bool>(initialState: false)

	/// Idempotent. Call once early in app lifecycle. Non-isolated so the
	/// `App.init` site can call it without bouncing through a Task.
	nonisolated static func startMonitoring() {
		let warmer = shared

		let claimed = warmer._monitoringStarted.withLock { state -> Bool in
			if state { return false }
			state = true
			return true
		}
		guard claimed else { return }

		warmer.pathMonitor.pathUpdateHandler = { [weak warmer] path in
			guard let warmer else { return }
			let wifi = path.status == .satisfied
				&& path.usesInterfaceType(.wifi)
			warmer._pathSatisfied.withLock { $0 = wifi }
		}
		warmer.pathMonitor.start(queue: warmer.pathMonitorQueue)

		#if os(iOS)
			// UIDevice is `@MainActor`-isolated; one-shot bounce to main to
			// seed state, then the observer keeps the cache fresh so
			// `conditionsFavorable` stays synchronous.
			Task { @MainActor in
				UIDevice.current.isBatteryMonitoringEnabled = true
				let state = UIDevice.current.batteryState
				warmer._externalPowerConnected.withLock { $0 = (state == .charging || state == .full) }

				NotificationCenter.default.addObserver(
					forName: UIDevice.batteryStateDidChangeNotification,
					object: nil,
					queue: .main
				) { [weak warmer] _ in
					guard let warmer else { return }
					MainActor.assumeIsolated {
						let state = UIDevice.current.batteryState
						let powered = (state == .charging || state == .full)
						warmer._externalPowerConnected.withLock { $0 = powered }
					}
				}
			}
		#endif
	}

	#if os(iOS)
		/// Register the BGTask handler. Must be called before the app
		/// finishes launching (from `App.init`) or the scheduler refuses
		/// our identifier.
		nonisolated static func registerBackgroundTask() {
			BGTaskScheduler.shared.register(
				forTaskWithIdentifier: bgTaskIdentifier,
				using: nil
			) { task in
				guard let processingTask = task as? BGProcessingTask else {
					task.setTaskCompleted(success: false)
					return
				}
				Task { await LibraryEmbeddingWarmer.shared.handleBackgroundTask(processingTask) }
			}
		}

		/// Submit a future BGProcessingTask. Safe to call repeatedly — the
		/// scheduler treats duplicates as updates.
		nonisolated static func scheduleNextBackgroundTask() {
			let request = BGProcessingTaskRequest(identifier: bgTaskIdentifier)
			request.requiresNetworkConnectivity = true
			request.requiresExternalPower = true
			request.earliestBeginDate = Date(timeIntervalSinceNow: bgTaskRefireDelay)
			try? BGTaskScheduler.shared.submit(request)
		}

		private func handleBackgroundTask(_ task: BGProcessingTask) async {
			// Re-arm before doing work so an unclean crash/expiry still re-fires.
			Self.scheduleNextBackgroundTask()

			let workTask = Task { await runWarmPass(requirePower: true) }
			task.expirationHandler = { workTask.cancel() }
			_ = await workTask.value
			task.setTaskCompleted(success: true)
		}
	#endif

	/// Run one warm pass. Returns when the eligible queue is empty,
	/// conditions become unfavourable, or the surrounding task is
	/// cancelled. Concurrent callers are coalesced — second caller
	/// no-ops while the first is still running.
	func runWarmPass(requirePower: Bool) async {
		if isRunning { return }
		isRunning = true
		defer { isRunning = false }

		guard conditionsFavorable(requirePower: requirePower) else { return }

		let union: [Song]
		do {
			union = try await librarySnapshot()
		} catch {
			return
		}

		// Genre hydration. `MusicLibraryRequest` songs come back with empty
		// `genreNames`; genres only exist on the `.genres` relationship,
		// hydrated per song. Run first and on a short breath — lightest pass,
		// broadest impact, so it lands before the heavier embed pass.
		let genreResolved = await GenreStore.shared.resolvedIDs(for: union.map(\.id))
		for song in union where !genreResolved.contains(song.id.rawValue) {
			if Task.isCancelled { return }
			if !conditionsFavorable(requirePower: requirePower) { return }

			// Record only on success — a thrown error is transient, so leave
			// the song unresolved to retry rather than caching an empty list.
			if let hydrated = try? await song.with([.genres]) {
				await GenreStore.shared.store(hydrated.genres?.map(\.name) ?? [], for: song.id)
			}
			try? await Task.sleep(for: Self.genreBreath)
		}

		for song in await embeddingEligible(union) {
			if Task.isCancelled { return }
			if !conditionsFavorable(requirePower: requirePower) { return }

			do {
				try await AudioEmbeddingService.ensureCached(song: song)
			} catch {
				// Permanent failures are negative-cached inside `ensureCached`;
				// transient errors are silently retried next pass.
			}

			try? await Task.sleep(for: Self.breath)
		}

		// Second pass: original-release-date resolution for unlooked-up songs.
		let resolved = await OriginalReleaseStore.shared.resolvedIDs(for: union.map(\.id))
		for song in union where !resolved.contains(song.id.rawValue) {
			if Task.isCancelled { return }
			if !conditionsFavorable(requirePower: requirePower) { return }

			try? await OriginalReleaseResolver.resolveAndStore(song: song)
			try? await Task.sleep(for: Self.breath)
		}

		// Last pass: re-detect BPM for rows whose cached value came from an
		// older detector version. Re-downloads the preview but skips
		// AudioFeaturePrint, so the embedding vector is preserved; reads keep
		// serving the old BPM until each is overwritten, so there's no blackout.
		let staleBPM = await EmbeddingStore.shared.staleBPMIDs(for: union.map(\.id))
		if !staleBPM.isEmpty {
			let failedIDs = await EmbeddingStore.shared.recentFailures(within: Self.failureRetryAfter)
			for song in union
				where staleBPM.contains(song.id.rawValue) && !failedIDs.contains(song.id.rawValue)
			{
				if Task.isCancelled { return }
				if !conditionsFavorable(requirePower: requirePower) { return }

				try? await AudioEmbeddingService.redetectBPM(song: song)
				try? await Task.sleep(for: Self.breath)
			}
		}
	}

	/// Synchronous read of cached gating state; cheap to call between embeds.
	/// WiFi is always required. Background passes require external power;
	/// foreground passes run on battery but defer to Low Power Mode — without
	/// the battery path a rarely-charged-on-WiFi phone never embeds past its
	/// deck.
	private nonisolated func conditionsFavorable(requirePower: Bool) -> Bool {
		guard _pathSatisfied.withLock({ $0 }) else { return false }
		if requirePower {
			return _externalPowerConnected.withLock { $0 }
		}
		return !ProcessInfo.processInfo.isLowPowerModeEnabled
	}

	/// Three-pool union of library songs, mirroring the deck builder's pools
	/// so the warmer hits the same songs each axis surfaces. Capped at
	/// `libraryCap`. Also drives the Library Overview's analysis-pool stats.
	func librarySnapshot() async throws -> [Song] {
		if let cached = cachedUnion, Date().timeIntervalSince(cached.at) < Self.unionCacheTTL {
			return cached.songs
		}
		let union = try await fetchUnion()
		cachedUnion = (union, Date())
		return union
	}

	private func fetchUnion() async throws -> [Song] {
		async let nostalgia = fetchPool(sort: .playCount, ascending: false)
		async let discovery = fetchPool(sort: .libraryAddedDate, ascending: true)
		async let freshness = fetchPool(sort: .libraryAddedDate, ascending: false)

		var seen = Set<MusicItemID>()
		var union: [Song] = []
		union.reserveCapacity(Self.libraryCap)
		for song in try await nostalgia where seen.insert(song.id).inserted {
			union.append(song)
			if union.count >= Self.libraryCap { break }
		}
		if union.count < Self.libraryCap {
			for song in try await discovery where seen.insert(song.id).inserted {
				union.append(song)
				if union.count >= Self.libraryCap { break }
			}
		}
		if union.count < Self.libraryCap {
			for song in try await freshness where seen.insert(song.id).inserted {
				union.append(song)
				if union.count >= Self.libraryCap { break }
			}
		}
		return union
	}

	/// Filter the union to songs missing either signal (embedding or BPM).
	/// `ensureCached` decides per-song between full pipeline and BPM-only
	/// backfill. Recently-failed songs are skipped.
	private func embeddingEligible(_ union: [Song]) async -> [Song] {
		let cached = await EmbeddingStore.shared.embeddings(for: union.map(\.id))
		let cachedEmbeddingIDs = Set(cached.keys.map(\.rawValue))
		let cachedBPMIDs = Set(
			await EmbeddingStore.shared.bpms(for: union.map(\.id)).keys.map(\.rawValue)
		)
		let failedIDs = await EmbeddingStore.shared.recentFailures(within: Self.failureRetryAfter)
		return union.filter { song in
			let raw = song.id.rawValue
			if failedIDs.contains(raw) { return false }
			let hasEmbedding = cachedEmbeddingIDs.contains(raw)
			let hasBPM = cachedBPMIDs.contains(raw)
			return !(hasEmbedding && hasBPM)
		}
	}

	private enum PoolSort {
		case playCount
		case libraryAddedDate
	}

	/// Paginated fetch up to `perPoolFetch`. We still page via `hasNextBatch`
	/// in case MusicKit silently caps the first response below the limit.
	private func fetchPool(sort: PoolSort, ascending: Bool) async throws -> [Song] {
		var request = MusicLibraryRequest<Song>()
		switch sort {
		case .playCount:
			request.sort(by: \.playCount, ascending: ascending)
		case .libraryAddedDate:
			request.sort(by: \.libraryAddedDate, ascending: ascending)
		}
		request.limit = Self.perPoolFetch
		let response = try await request.response()

		var items: [Song] = []
		items.reserveCapacity(Self.perPoolFetch)
		items.append(contentsOf: response.items)

		var latest = response.items
		while items.count < Self.perPoolFetch, latest.hasNextBatch {
			guard let next = try? await latest.nextBatch() else { break }
			items.append(contentsOf: next)
			latest = next
		}

		return items
	}
}
