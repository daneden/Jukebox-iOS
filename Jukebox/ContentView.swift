//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

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
	}
}

enum AppTab: String, CaseIterable {
	case playlists
	case songs
}

#Preview {
	ContentView()
}
