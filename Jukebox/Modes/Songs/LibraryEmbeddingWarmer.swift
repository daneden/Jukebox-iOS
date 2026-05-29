//
//  LibraryEmbeddingWarmer.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Long-tail audio-embedding warmer. `GemDeckBuilder.warmEmbeddings`
//  handles the current 300-song deck synchronously after it's built;
//  this warmer takes everything *else* — capped at the top ~10k
//  library songs by play-count and library-add date — and chews
//  through them while the user isn't waiting.
//
//  Why expand past the deck: `SongDeckWalk.similarity` falls back to a
//  metadata-only blend (genre + era) whenever either side of a
//  candidate pair lacks a cached embedding. The walk can't promote a
//  song into the deck on real sonic similarity if it's never been
//  embedded. Warming the long tail means decks built under different
//  filter combos, or after library mutations, start with audio
//  similarity instead of the fallback.
//
//  Gating — checked at entry and between each song. WiFi is always
//  required; the power requirement depends on which mode is running
//  (see `conditionsFavorable(requirePower:)`):
//   - WiFi reachable (`NWPathMonitor`). 30s previews are ~500KB; a
//     full 10k pass is ~5GB of downloads, which we won't burn on
//     cellular.
//   - Power: background passes require external power; foreground
//     passes run on battery but defer to Low Power Mode.
//
//  Triggered in two modes:
//   - Foreground opportunistic: kicked from `GemDeckBuilder` after
//     deck-warm finishes, `requirePower: false`. Runs at `.utility`
//     QoS so it doesn't compete with the dial, on battery as long as
//     the user isn't in Low Power Mode. Without the battery path the
//     warmer never progressed for a phone that's rarely charged on
//     WiFi — it bailed on every battery session. No-op if conditions
//     aren't met.
//   - Background processing: via `BGProcessingTask` on iOS, registered
//     with `requiresExternalPower` + `requiresNetworkConnectivity`, run
//     `requirePower: true`. The system only wakes us when those are
//     mostly satisfied; WiFi is re-checked at handler entry because
//     `requiresNetworkConnectivity` doesn't differentiate WiFi from
//     cellular — cellular runs return immediately and reschedule.
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

	/// Hard cap on how many library songs we'll embed beyond the active
	/// deck. A 50k-song library × ~500KB preview is ~25GB if we go
	/// all-in; capping keeps the bandwidth + storage budget bounded
	/// while still covering the songs most likely to influence future
	/// decks (top playCount + oldest library entries).
	static let libraryCap = 10000

	/// Per-pool fetch ceiling. Union of two pools, deduped, capped at
	/// `libraryCap`. Set so the union *can* reach the cap even when
	/// pools overlap heavily.
	static let perPoolFetch = 5000

	/// Sleep between songs in the warm loop. Longer than the deck
	/// warmer's 200ms — nobody's waiting for the long tail, and a
	/// gentler cadence is friendlier on battery + Apple's preview CDN.
	static let breath: Duration = .milliseconds(500)

	/// Sleep between songs in the genre-hydration loop. Much shorter than
	/// `breath` — `.with([.genres])` is a lightweight relationship fetch,
	/// no audio download — so the broadest-impact signal fills quickly.
	static let genreBreath: Duration = .milliseconds(80)

	/// Window during which a permanently-failed song stays in the
	/// negative cache. After this we retry once — Apple's catalog
	/// occasionally backfills previews for older library items.
	static let failureRetryAfter: TimeInterval = 60 * 86400

	#if os(iOS)
		/// Must match the entry in `Info.plist` →
		/// `BGTaskSchedulerPermittedIdentifiers`. Registered at app launch;
		/// scheduled after each handler run and after the foreground warmer
		/// finishes a pass.
		static let bgTaskIdentifier = "me.daneden.Jukebox.libraryEmbedding"

		/// Earliest re-fire delay for the background task. The scheduler
		/// treats this as a hint, not a guarantee; iOS may delay
		/// significantly based on usage patterns. 4h keeps us out of the
		/// system's "this app is hungry" doghouse while still giving
		/// multiple chances per day.
		static let bgTaskRefireDelay: TimeInterval = 4 * 60 * 60
	#endif

	private var isRunning = false

	// Cached gating state, updated by background callbacks (NWPathMonitor
	// path queue, UIDevice notifications on main). Kept in a lock so
	// `conditionsFavorable` can be a synchronous nonisolated read in
	// the warm loop's hot path.
	private nonisolated let pathMonitor = NWPathMonitor()
	private nonisolated let pathMonitorQueue = DispatchQueue(
		label: "me.daneden.Jukebox.LibraryEmbeddingWarmer.path"
	)
	private nonisolated let _pathSatisfied = OSAllocatedUnfairLock<Bool>(initialState: false)
	// Defaults to true so non-iOS targets (macOS) — where we don't
	// observe battery state at all — read as "powered."
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
			// UIDevice is `@MainActor`-isolated. Setting up battery
			// monitoring + seeding the cached state is a one-shot bounce
			// to main; afterwards the notification observer keeps the
			// cache fresh and `conditionsFavorable` stays synchronous.
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
		/// finishes launching (i.e. from `App.init`), otherwise the
		/// scheduler refuses our identifier.
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

		/// Submit a future BGProcessingTask. Safe to call repeatedly —
		/// the scheduler treats duplicates as updates. We call this on
		/// foreground warm-pass completion *and* after each BGTask run
		/// so the queue stays primed.
		nonisolated static func scheduleNextBackgroundTask() {
			let request = BGProcessingTaskRequest(identifier: bgTaskIdentifier)
			request.requiresNetworkConnectivity = true
			request.requiresExternalPower = true
			request.earliestBeginDate = Date(timeIntervalSinceNow: bgTaskRefireDelay)
			try? BGTaskScheduler.shared.submit(request)
		}

		private func handleBackgroundTask(_ task: BGProcessingTask) async {
			// Re-arm the next run *before* doing work — if the handler
			// crashes or expires uncleanly, we still get re-fired later.
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

		// Genre hydration. Bare `MusicLibraryRequest` songs come back with
		// an empty `genreNames`; the genres only exist on the `.genres`
		// relationship, which has to be hydrated per song. Cache the names
		// so the energy fallback, the deck builders' band slices, and the
		// walk's genre blend have a signal to read. Run first and on a
		// short breath — it's the lightest pass and the broadest in impact,
		// so it should land before the heavier embed pass across sessions.
		let genreResolved = await GenreStore.shared.resolvedIDs(for: union.map(\.id))
		for song in union where !genreResolved.contains(song.id.rawValue) {
			if Task.isCancelled { return }
			if !conditionsFavorable(requirePower: requirePower) { return }

			// Only record on a successful hydration — a thrown error is
			// transient, so leave the song unresolved to retry next pass
			// rather than caching an empty list it doesn't deserve.
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
				// Permanent failures are negative-cached inside
				// `ensureCached`; transient errors (downloadFailed)
				// are silently retried next pass.
			}

			try? await Task.sleep(for: Self.breath)
		}

		// Second pass: original-release-date resolution for songs we
		// haven't yet looked up. Same WiFi + power gate, same 500ms
		// breath. The resolver fires a catalog request per song so the
		// budget shape matches embeds — but each row is a small Date
		// rather than a 2KB vector, so the cache scales fine to the
		// full long-tail.
		let resolved = await OriginalReleaseStore.shared.resolvedIDs(for: union.map(\.id))
		for song in union where !resolved.contains(song.id.rawValue) {
			if Task.isCancelled { return }
			if !conditionsFavorable(requirePower: requirePower) { return }

			try? await OriginalReleaseResolver.resolveAndStore(song: song)
			try? await Task.sleep(for: Self.breath)
		}

		// Last pass: re-detect BPM for rows whose cached value came from an
		// older detector version. Lowest priority — it improves existing
		// data, where the earlier passes fill missing data. Re-downloads
		// the preview but skips AudioFeaturePrint, so the embedding vector
		// is preserved; reads keep serving the old BPM until each is
		// overwritten, so there's no blackout. The negative-failure cache
		// keeps unresolvable songs from re-downloading every pass.
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

	/// Synchronous read of the latest cached gating state. Cheap enough
	/// to call between every embed.
	///
	/// WiFi is always required — a full pass is ~5GB, never on cellular.
	/// The power requirement is conditional on who's asking:
	///   - Background passes (`requirePower: true`) require external
	///     power, so an unattended pass never drains the battery while
	///     the user isn't even in the app.
	///   - Foreground passes (`requirePower: false`) run on battery too,
	///     but defer to Low Power Mode: if the user has signalled "save
	///     battery," we don't compete. Without this the foreground pass
	///     bailed on every battery session, so a phone that's rarely
	///     charged-on-WiFi never embedded past its deck.
	private nonisolated func conditionsFavorable(requirePower: Bool) -> Bool {
		guard _pathSatisfied.withLock({ $0 }) else { return false }
		if requirePower {
			return _externalPowerConnected.withLock { $0 }
		}
		return !ProcessInfo.processInfo.isLowPowerModeEnabled
	}

	/// Three-pool union of library songs (mirrors the deck builder's
	/// pools so the long-tail warmer hits the same songs each axis
	/// will surface). Capped at `libraryCap`. Also exposed so the
	/// Library Overview view can compute its analysis-pool stats over
	/// the same set the warmer will actually embed.
	func librarySnapshot() async throws -> [Song] {
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

	/// Filter the union to songs that need an embedding pass — either
	/// signal missing (embedding or BPM). `ensureCached` decides
	/// per-song between "full pipeline" (no embedding yet) and "BPM-
	/// only backfill" (embedding cached but BPM nil). Recently-failed
	/// songs are skipped at both layers.
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

	/// Paginated fetch up to `Self.perPoolFetch` results. `MusicLibraryRequest.limit`
	/// is documented small (25 default) but in practice accepts larger
	/// values; we still paginate via `hasNextBatch` in case MusicKit
	/// silently caps the first response.
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
