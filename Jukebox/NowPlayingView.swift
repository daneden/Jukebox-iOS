//
//  NowPlayingView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import MusicKit
import SwiftUI

struct NowPlayingView: View {
	@Binding var playlist: Playlist?
	@Environment(\.openURL) private var openURL

	var body: some View {
		HStack(spacing: 12) {
			cover
				.frame(width: 36, height: 36)

			VStack(alignment: .leading, spacing: 1) {
				Text(playlist?.name ?? "Nothing playing")
					.fontWeight(.semibold)
					.contentTransition(.numericText())

				Text(subtitle)
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
			.font(.footnote)
			.lineLimit(1)

			Spacer(minLength: 0)

			if playlist != nil {
				Image(systemName: "arrow.up.forward.app")
					.foregroundStyle(.tertiary)
					.imageScale(.large)
					.transition(.blurReplace)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal)
		.frame(maxWidth: .infinity, alignment: .leading)
		.glassEffect(in: .capsule)
		.foregroundStyle(.primary)
		.contentShape(.capsule)
		.onTapGesture(perform: openCurrent)
		.animation(.smooth(duration: 0.35), value: playlist?.id)
	}

	private var subtitle: String {
		playlist == nil ? "Tap shuffle to play a random playlist" : "Open in Apple Music"
	}

	@ViewBuilder
	private var cover: some View {
		if let playlist, let artwork = playlist.artwork {
			ArtworkImage(artwork, width: 36)
				.clipShape(.rect(cornerRadius: 6, style: .continuous))
				.id(playlist.id)
				.transition(.blurReplace)
		} else {
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(.thinMaterial)
				.overlay {
					Image(systemName: "music.note")
						.foregroundStyle(.tertiary)
						.font(.footnote)
				}
				.id("empty-cover")
				.transition(.blurReplace)
		}
	}

	private func openCurrent() {
		guard let playlist,
		      let url = playlist.url ?? URL(string: "music://music.apple.com/library/playlist/\(playlist.id)")
		else { return }
		openURL(url)
	}
}

#Preview {
	NowPlayingView(playlist: .constant(nil))
		.padding()
}
