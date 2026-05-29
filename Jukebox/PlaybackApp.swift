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
			// `BGTaskScheduler.register` must run before the app finishes launching.
			LibraryEmbeddingWarmer.registerBackgroundTask()
		#endif
		// Warmer gating is a synchronous read of cached state, so start the WiFi +
		// battery monitors as early as possible.
		LibraryEmbeddingWarmer.startMonitoring()

		// Must run before any TipView renders.
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
