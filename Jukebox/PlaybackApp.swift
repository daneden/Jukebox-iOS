//
//  PlaybackApp.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import SwiftUI
import TipKit

@main
struct PlaybackApp: App {
	init() {
		#if os(iOS)
			// `BGTaskScheduler.register` has to run before the app finishes
			// launching, so we do it here rather than in a `.task` modifier.
			// The handler itself just bounces work into the warmer actor.
			LibraryEmbeddingWarmer.registerBackgroundTask()
		#endif
		// Start WiFi + battery state observation. The warmer's gating is
		// a synchronous read of the latest cached state, so we want the
		// monitors live as early as possible.
		LibraryEmbeddingWarmer.startMonitoring()

		// Must run before any TipView renders; init is the earliest point.
		try? Tips.configure([
			.displayFrequency(.immediate),
			.datastoreLocation(.applicationDefault),
		])
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
		}
		.defaultSize(width: 500, height: 600)
	}
}
