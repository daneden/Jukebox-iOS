//
//  NowPlayingView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import SwiftUI
import UIKit
import MusicKit

struct NowPlayingView: View {
	var playlist: Playlist?
	
	var body: some View {
		if let playlist {
			HStack {
				if let artwork = playlist.artwork {
					ArtworkImage(artwork, width: 40)
						.clipShape(RoundedRectangle(cornerRadius: 6))
						#if DEBUG
						.onTapGesture(count: 3) {
							if let encoded = try? JSONEncoder().encode(playlist),
								 let string = String(data: encoded, encoding: .utf8) {
								UIPasteboard.general.string = string
							}
						}
						#endif
				}
				
				VStack(alignment: .leading) {
					Text(playlist.name)
						.font(.headline)
					if let url = playlist.url ?? URL(string: "music://music.apple.com/library/playlist/\(playlist.id)") {
						Link(destination: url) {
							Label("Open in Apple Music", systemImage: "music.note")
								.imageScale(.small)
						}
						.foregroundStyle(.secondary)
					}
				}
			}
			.padding(8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(.regularMaterial)
			.clipShape(RoundedRectangle(cornerRadius: 16))
			.padding(.leading, -8)
			.transition(
				.move(edge: .leading)
				.combined(with: .scale)
			)
		}
	}
}

#Preview {
	NowPlayingView()
}
