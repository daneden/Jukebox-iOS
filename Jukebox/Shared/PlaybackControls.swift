//
//  PlaybackControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// Bottom-aligned Play + Shuffle pair shared by Playlists and Songs modes.
/// Play immediately plays whatever is focused; Shuffle's behavior is
/// owned by the caller — Playlists rotates the dial, Songs rebuilds the
/// deck — so this view is a dumb action surface.
struct PlaybackControls: View {
	@Environment(\.colorScheme) private var colorScheme
	let disabled: Bool
	let onPlay: () async -> Void
	let onShuffle: () async -> Void

	var body: some View {
		GlassEffectContainer(spacing: 8) {
			HStack(spacing: 8) {
				AsyncButton(action: onPlay) {
					Label("Play", systemImage: "play.fill")
						.frame(maxWidth: .infinity)
				}
				.fontWeight(.bold)
				.buttonStyle(.glass)
				.buttonBorderShape(.capsule)
				.controlSize(.extraLarge)
				.disabled(disabled)

				AsyncButton(action: onShuffle) {
					Label("Shuffle", systemImage: "shuffle")
						.frame(maxWidth: .infinity)
						.foregroundStyle(colorScheme == .dark ? .black : .white)
				}
				.fontWeight(.bold)
				.buttonStyle(.glassProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.extraLarge)
				.disabled(disabled)
			}
			.frame(height: 56)
		}
		.scenePadding(.horizontal)
		#if os(iOS)
			// macOS windows have their own bottom chrome margin already; the
			// extra scenePadding here makes the bar float too far above the
			// window's bottom edge.
			.scenePadding(.bottom)
		#endif
	}
}
