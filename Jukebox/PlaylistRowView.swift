//
//  PlaylistRowView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import MusicKit
import SwiftUI

struct PlaylistRowView: View {
	@State var playlist: Playlist

	var body: some View {
		HStack {
			if let artwork = playlist.artwork {
				ArtworkImage(artwork, width: 60)
					.clipShape(RoundedRectangle(cornerRadius: 4))
			}

			VStack(alignment: .leading) {
				Text(playlist.name)

				Group {
					if let curatorName = playlist.curatorName {
						Text(curatorName)
							.font(.subheadline)
					}

					Text("\(playlist.tracks?.count ?? 0) songs")
						.font(.callout)
				}.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.task {
			if let detailedPlaylist = try? await playlist.with([.tracks]) {
				self.playlist = detailedPlaylist
			}
		}
	}
}

// #Preview {
//    PlaylistRowView()
// }
