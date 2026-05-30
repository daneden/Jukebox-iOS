//
//  PlaybackControls.swift
//  Widgets
//
//  Control Center controls for Playback. Each binds a thin foreground intent
//  (see ControlSupport.swift) that brings the app forward and queues the
//  action; the app does the heavy lifting.
//

import AppIntents
import SwiftUI
import WidgetKit

struct PlayRandomPlaylistControl: ControlWidget {
	var body: some ControlWidgetConfiguration {
		StaticControlConfiguration(kind: "me.daneden.Jukebox.control.random") {
			ControlWidgetButton(action: PlayRandomPlaylistControlIntent()) {
				Label("Random Playlist", systemImage: "shuffle")
			}
		}
		.displayName("Play Random Playlist")
		.description("Play a random playlist from your Apple Music library.")
	}
}

struct MakeGemsControl: ControlWidget {
	var body: some ControlWidgetConfiguration {
		StaticControlConfiguration(kind: "me.daneden.Jukebox.control.gems") {
			ControlWidgetButton(action: MakeGemsControlIntent()) {
				Label("Make a Playlist", systemImage: "sparkles")
			}
		}
		.displayName("Make a Playlist")
		.description("Build and play a playlist of hidden gems.")
	}
}
