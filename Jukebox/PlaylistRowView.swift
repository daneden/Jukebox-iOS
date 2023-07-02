//
//  PlaylistRowView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import SwiftUI
import MusicKit

struct PlaylistRowView: View {
	@State var playlist: Playlist
	
	var body: some View {
		HStack {
			if let artwork = playlist.artwork {
				ArtworkImage(artwork, width: 40)
						.clipShape(RoundedRectangle(cornerRadius: 4))
			}
			
			VStack(alignment: .leading) {
				Text(playlist.name)
				Text("\(playlist.tracks?.count ?? 0) songs")
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.task {
			if let detailedPlaylist = try? await playlist.with([.tracks]) {
				playlist = detailedPlaylist
			}
		}
	}
}

//#Preview {
//    PlaylistRowView()
//}
