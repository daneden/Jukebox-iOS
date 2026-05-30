//
//  OnboardingTips.swift
//  Jukebox
//
//  One-time "what is this tab for" tips pinned to the top of each main tab.
//  Distinct from the first-run `OnboardingView` sheet (which handles Apple Music
//  authorization). Show-once persistence via TipKit's datastore (configured in
//  `PlaybackApp.init`).
//

import SwiftUI
import TipKit

struct SongsTip: Tip {
	var title: Text {
		Text("Songs")
	}

	var message: Text? {
		Text("Rediscover old favourites, new arrivals, and hidden gems. Hit shuffle to see a new mix.")
	}

	var image: Image? {
		Image(systemName: "sparkles")
	}
}

struct PlaylistsTip: Tip {
	var title: Text {
		Text("Playlists")
	}

	var message: Text? {
		Text("Flick the dial or hit shuffle to land on a playlist you forgot you saved.")
	}

	var image: Image? {
		Image(systemName: "music.note.list")
	}
}

struct DesignTip: Tip {
	var title: Text {
		Text("Design")
	}

	var message: Text? {
		Text("Create playlists from your library based on their energy. Works best after a few days of use.")
	}

	var image: Image? {
		Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
	}
}

extension View {
	/// The stacked top safe-area insets every tab shares: the dismissible tip, and
	/// on macOS (no principal-toolbar slot) the Playback wordmark above it. Both sit
	/// outside the content `VStack` so neither enters the dial's animation scope.
	///
	/// Applied tip-first so the macOS wordmark inset is the outer (topmost) one:
	/// wordmark → tip → content.
	func tabHeader(tip: some Tip) -> some View {
		safeAreaInset(edge: .top, spacing: 0) {
			TipView(tip)
				.padding(.horizontal)
				#if os(macOS)
				.padding(.top, 8)
				#else
				.padding(.bottom)
				#endif
		}
		#if os(iOS)
		.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
		.safeAreaInset(edge: .top, spacing: 0) {
			ToolbarLogo()
				.frame(maxWidth: .infinity)
				.padding(.top, 8)
		}
		#endif
	}
}
