//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import SwiftUI
import MusicKit

struct ContentView: View {
	private var libraryManager = LibraryManager.shared
	private let player = SystemMusicPlayer.shared
	
	@State private var chosenPlaylist: Playlist?
	@State private var shuffle = true
	
	var item: MusicPlayer.Queue.Entry? {
		player.queue.currentEntry
	}
	
	var body: some View {
		NavigationView {
			GeometryReader { geometry in
				ZStack(alignment: .bottom) {
					ScrollView {
						VStack {
							switch MusicAuthorization.currentStatus {
							case .notDetermined:
								Group {
									Spacer()
									Text("Get Started")
										.font(.headline)
									Text("Jukebox needs access to your Apple Music library. Tap “Allow Access” to get started.")
									Button("Allow Access") {
										Task {
											let authStatus = await MusicAuthorization.request()
											if authStatus == .authorized {
												await libraryManager.getPlaylists()
											}
										}
									}
									.buttonStyle(.borderedProminent)
									Spacer()
								}
							case .authorized:
								HStack {
									Button {
										Task { await playRandom() }
									} label: {
										Label("Play Random Playlist", systemImage: "music.note.list")
											.frame(maxWidth: .infinity)
									}
									.buttonStyle(.borderedProminent)
									.controlSize(.extraLarge)
									.disabled(libraryManager.playlists.isEmpty)
								}
								
								if libraryManager.playlists.isEmpty {
									Spacer()
									Text("No Playlists")
										.foregroundStyle(.secondary)
									Spacer()
								} else {
									ForEach(libraryManager.playlists) { playlist in
										Text(playlist.name)
									}
								}
								
							default:
								Text("Something went wrong")
							}
						}
						.scenePadding()
						.frame(minHeight: geometry.size.height)
					}
					
					if let playlist = chosenPlaylist {
						HStack {
							if let artwork = playlist.artwork?.url(width: 80, height: 80) {
								AsyncImage(url: artwork)
									.transition(.move(edge: .leading).combined(with: .opacity))
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
					}
				}
			}
			.navigationTitle("Jukebox")
			.symbolRenderingMode(.hierarchical)
			.task {
				await libraryManager.getPlaylists()
			}
		}
	}
	
	func playRandom() async {
		if let playlist = libraryManager.playlists.randomElement() {
			self.chosenPlaylist = playlist
			playPlaylist(playlist: playlist)
		}
	}
	
	func playPlaylist(playlist: Playlist) {
		Task {
			try? await player.queue.insert(playlist, position: .afterCurrentEntry)
			try? await player.skipToNextEntry()
			try? await player.play()
		}
	}
}

struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		ContentView()
	}
}


extension Collection {
	func randomElement() -> Element {
		return self[Int.random(in: 0...self.count) as! Self.Index]
	}
}
