//
//  PlaybackControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// Bottom-aligned Play + Shuffle pair shared by Playlists and Songs modes.
/// Play immediately plays whatever is focused; Shuffle rotates the dial
/// (and lets the caller decide whether to auto-play based on the user's
/// Autoplay preference). When `onSuperShuffle` is provided, long-pressing
/// the Shuffle button surfaces a "Super Shuffle" context-menu action.
struct PlaybackControls: View {
	@Environment(\.colorScheme) private var colorScheme
	let disabled: Bool
	let onPlay: () async -> Void
	let onShuffle: () async -> Void
	var onSuperShuffle: (() async -> Void)? = nil

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
				.controlSize(.large)
				.disabled(disabled)

				AsyncButton(action: onShuffle) {
					Label("Shuffle", systemImage: "shuffle")
						.frame(maxWidth: .infinity)
						.foregroundStyle(colorScheme == .dark ? .black : .white)
				}
				.fontWeight(.bold)
				.buttonStyle(.glassProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.large)
				.disabled(disabled)
				.contextMenu {
					if let onSuperShuffle {
						Button {
							Task { await onSuperShuffle() }
						} label: {
							Label("Super Shuffle", systemImage: "shuffle.circle.fill")
						}
					}
				}
			}
			.frame(height: 56)
		}
		.scenePadding(.horizontal)
		.scenePadding(.bottom)
	}
}
