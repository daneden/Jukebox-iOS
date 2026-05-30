//
//  PlaybackControls.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// Bottom-aligned Play + Shuffle pair shared by Playlists and Songs modes.
/// Shuffle's behavior is owned by the caller. Optional `leading` slot shares
/// the same glass container so the effect merges with Play + Shuffle.
struct PlaybackControls<Leading: View>: View {
	@Environment(\.colorScheme) private var colorScheme
	@AppStorage(SettingsKeys.autoplay) private var autoplay = true
	@AppStorage(SettingsKeys.askedShuffleAutoplay) private var askedShuffleAutoplay = false
	@State private var showingAutoplayPrompt = false
	let disabled: Bool
	let onPlay: () async -> Void
	let onShuffle: () async -> Void
	@ViewBuilder let leading: Leading

	var body: some View {
		GlassEffectContainer(spacing: 8) {
			HStack(spacing: 8) {
				leading

				AsyncButton(action: onPlay) {
					Label("Play", systemImage: "play.fill")
						.frame(maxWidth: .infinity)
				}
				.fontWeight(.bold)
				.buttonStyle(.glass)
				.buttonBorderShape(.capsule)
				.disabled(disabled)

				AsyncButton(action: handleShuffle) {
					Label("Shuffle", systemImage: "shuffle")
						.frame(maxWidth: .infinity)
						.foregroundStyle(colorScheme == .dark ? .black : .white)
				}
				.fontWeight(.bold)
				.buttonStyle(.glassProminent)
				.buttonBorderShape(.capsule)
				.disabled(disabled)
			}
			.frame(height: 44)
		}
		.controlSize(.extraLarge)
		.scenePadding(.horizontal)
		.scenePadding(.bottom)
		.allowsTightening(true)
		.confirmationDialog(
			"Play automatically when you shuffle?",
			isPresented: $showingAutoplayPrompt,
			titleVisibility: .visible
		) {
			Button("Yes, start playing") { resolveAutoplay(true) }
			Button("No, just spin") { resolveAutoplay(false) }
		} message: {
			Text("Shuffle can start the result playing, or just spin to a suggestion and wait for you to press Play. Change this anytime in Settings.")
		}
	}

	/// First shuffle asks once whether to autoplay; after that, uses the saved preference.
	private func handleShuffle() async {
		if askedShuffleAutoplay {
			await onShuffle()
		} else {
			showingAutoplayPrompt = true
		}
	}

	private func resolveAutoplay(_ value: Bool) {
		autoplay = value
		askedShuffleAutoplay = true
		Task { await onShuffle() }
	}
}

extension PlaybackControls where Leading == EmptyView {
	init(
		disabled: Bool,
		onPlay: @escaping () async -> Void,
		onShuffle: @escaping () async -> Void
	) {
		self.init(disabled: disabled, onPlay: onPlay, onShuffle: onShuffle) {
			EmptyView()
		}
	}
}
