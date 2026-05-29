//
//  OnboardingTips.swift
//  Jukebox
//
//  One-time "what is this tab for" tips pinned to the top of each main tab.
//  Distinct from the first-run `OnboardingView` sheet (which only handles
//  Apple Music authorization) — these describe each tab's core purpose and
//  rely on TipKit's datastore for show-once / stay-dismissed persistence
//  (configured in `PlaybackApp.init`). Icons mirror the tab bar symbols in
//  `ContentView` for continuity.
//

import SwiftUI
import TipKit

struct SongsTip: Tip {
	var title: Text {
		Text("Hidden gems")
	}

	var message: Text? {
		Text("Spin the dial through songs that have gone quiet in your library, then tap to play.")
	}

	var image: Image? {
		Image(systemName: "sparkles")
	}
}

struct PlaylistsTip: Tip {
	var title: Text {
		Text("Spin your playlists")
	}

	var message: Text? {
		Text("Flick the dial to land on a playlist you forgot you saved.")
	}

	var image: Image? {
		Image(systemName: "music.note.list")
	}
}

struct DesignTip: Tip {
	var title: Text {
		Text("Design by energy")
	}

	var message: Text? {
		Text("Draw a curve from calm to intense and Playback builds a playlist that follows it.")
	}

	var image: Image? {
		Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
	}
}

extension View {
	/// Pins a dismissible onboarding `TipView` to the top of a tab. The inset
	/// sits outside the tab's content `VStack`, so it never enters the dial's
	/// animation scope; `TipView` collapses to nothing once the tip is
	/// dismissed (its state persists via TipKit's datastore).
	func tabOnboardingTip(_ tip: some Tip) -> some View {
		safeAreaInset(edge: .top, spacing: 0) {
			TipView(tip)
				.padding(.horizontal)
				.padding(.top, 8)
		}
	}
}
