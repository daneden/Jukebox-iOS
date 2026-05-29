//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import MusicKit
import SwiftUI

/// Tabs for the Playlists and Songs dials. Selection persists across launches.
struct ContentView: View {
	@AppStorage("selectedTab") private var selectedTab: AppTab = .songs

	/// Seeded from auth status so an already-authorized user never sees the sheet.
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

			DesignView()
				.tabItem {
					Label("Design", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
				}
				.tag(AppTab.design)
		}
		.sheet(isPresented: $showOnboarding) {
			OnboardingView {
				let status = await MusicAuthorization.request()
				#if os(macOS)
					// Group with library auth so first play isn't ambushed by a second prompt.
					_ = await AppleMusicScriptBridge.requestAutomationPermission()
				#endif
				if status != .notDetermined { showOnboarding = false }
			}
		}
		#if os(macOS)
		.task {
			// Covers the already-authorized path where onboarding never shows.
			// The underlying AE permission check is a no-op once cached.
			guard MusicAuthorization.currentStatus == .authorized else { return }
			_ = await AppleMusicScriptBridge.requestAutomationPermission()
		}
		#endif
	}
}

enum AppTab: String, CaseIterable {
	case playlists
	case songs
	case design
}

#Preview {
	ContentView()
}
