//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import MusicKit
import SwiftUI

/// Two equal-citizen modes:
/// - **Playlists** — the original dial-of-playlists for rediscovering an
///   album you forgot you saved.
/// - **Songs** — the dial-of-songs for rediscovering individual tracks
///   that have gone quiet in a big library.
///
/// Selection persists across launches so the user lands back where they were.
struct ContentView: View {
	@AppStorage("selectedTab") private var selectedTab: AppTab = .songs

	/// Drives the first-run onboarding sheet. Seeded from the current
	/// authorization status so an already-authorized user never sees the
	/// sheet; flipped to `false` once the user answers the system prompt.
	@State private var showOnboarding: Bool = MusicAuthorization.currentStatus == .notDetermined

	var body: some View {
		TabView(selection: $selectedTab) {
			SongsView()
				.tabItem {
					Label("Songs", systemImage: "sparkles")
				}
				.tag(AppTab.songs)

			PlaylistsView()
				.tabItem {
					Label("Playlists", systemImage: "music.note.list")
				}
				.tag(AppTab.playlists)
		}
		.sheet(isPresented: $showOnboarding) {
			OnboardingView {
				let status = await MusicAuthorization.request()
				#if os(macOS)
					// Group the Music.app automation prompt with the library auth
					// so the user isn't ambushed by a second prompt on first play.
					_ = await AppleMusicScriptBridge.requestAutomationPermission()
				#endif
				if status != .notDetermined { showOnboarding = false }
			}
		}
		#if os(macOS)
		.task {
			// Covers the already-authorized path where onboarding never shows.
			// `AEDeterminePermissionToAutomateTarget` is a no-op once cached,
			// so this is harmless if it also ran through the onboarding hook.
			guard MusicAuthorization.currentStatus == .authorized else { return }
			_ = await AppleMusicScriptBridge.requestAutomationPermission()
		}
		#endif
	}
}

enum AppTab: String, CaseIterable {
	case playlists
	case songs
}

#Preview {
	ContentView()
}
