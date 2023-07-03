//
//  PlaylistRowView.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import SwiftUI
import MusicKit

struct PlaylistRowView: View {
	@AppStorage("excludedPlaylistIds") private var excludedPlaylistIds: Array<Playlist.ID> = []
	
	@State var playlist: Playlist
	
	var isExcluded: Binding<Bool> {
		Binding {
			excludedPlaylistIds.firstIndex(of: playlist.id) != nil
		} set: { value in
			if let index = excludedPlaylistIds.firstIndex(of: playlist.id) {
				excludedPlaylistIds.remove(at: Int(index))
			} else {
				excludedPlaylistIds.append(playlist.id)
			}
		}
	}

	
	var body: some View {
		HStack {
			if let artwork = playlist.artwork {
				ArtworkImage(artwork, width: isExcluded.wrappedValue ? 40 : 60)
						.clipShape(RoundedRectangle(cornerRadius: 4))
			}
			
			VStack(alignment: .leading) {
				Text(playlist.name)
					.foregroundStyle(isExcluded.wrappedValue ? .secondary : .primary)
				
				Group {
					if !isExcluded.wrappedValue {
						if let curatorName = playlist.curatorName {
							Text(curatorName)
								.font(.subheadline)
						}
						
						Text("\(playlist.tracks?.count ?? 0) songs")
							.font(.callout)
							.foregroundStyle(.secondary)
					} else {
						Text("Excluded from shuffle")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contextMenu {
			Toggle(isOn: isExcluded.animation()) {
				Text("Exclude from shuffle")
			}
		}
		.task {
			if let detailedPlaylist = try? await playlist.with([.tracks]) {
				self.playlist = detailedPlaylist
			}
		}
	}
}

//#Preview {
//    PlaylistRowView()
//}
