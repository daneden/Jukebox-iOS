//
//  NowPlayingView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import SwiftUI
import MusicKit

struct NowPlayingView: View {
	var playlist: Playlist?
	
	var body: some View {
		if let playlist {
			HStack {
				if let artwork = playlist.artwork {
					ArtworkImage(artwork, width: 40)
				}
				
				VStack(alignment: .leading) {
					Text(playlist.name)
						.font(.headline)
					if let url = playlist.url {
						Link(destination: url) {
							Text("Open in Apple Music")
						}
						.foregroundStyle(.secondary)
					}
				}
			}
			.padding()
			.background(.thinMaterial)
			.clipShape(RoundedRectangle(cornerRadius: 20))
			.scenePadding()
			.transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale))
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

#Preview {
    NowPlayingView()
}
