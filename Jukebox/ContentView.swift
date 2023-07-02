//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import SwiftUI
import MusicKit

enum PlaylistSortProperty {
	case lastPlayedDate, libraryAddedDate, name
}

struct ContentView: View {
	private let player = SystemMusicPlayer.shared
	
	@State private var sortBy: PlaylistSortProperty = .lastPlayedDate
	@State private var sortAscending = false
	
	@State private var playlists: MusicItemCollection<Playlist> = []
	@State private var chosenPlaylist: Playlist?
	
	var item: MusicPlayer.Queue.Entry? {
		player.queue.currentEntry
	}
	
	var body: some View {
		NavigationView {
			GeometryReader { geometry in
				ScrollView {
					VStack {
						switch MusicAuthorization.currentStatus {
						case .notDetermined:
							VStack {
								Spacer()
								Text("Get Started")
									.font(.headline)
								Text("Jukebox needs access to your Apple Music library. Tap “Allow Access” to get started.")
								Button("Allow Access") {
									Task {
										await MusicAuthorization.request()
									}
								}
								.buttonStyle(.borderedProminent)
								Spacer()
							}
							.frame(maxWidth: .infinity)
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
								.disabled(playlists.isEmpty)
							}
							
							if playlists.isEmpty {
								Spacer()
								Text("No Playlists")
									.foregroundStyle(.secondary)
								Spacer()
							} else {
								ForEach(playlists) { playlist in
									PlaylistRowView(playlist: playlist)
								}
							}
							
						default:
							Text("Something went wrong")
						}
					}
					.scenePadding()
					.frame(minHeight: geometry.size.height)
				}
				.dataTask {
					await updatePlaylists()
				}
				.safeAreaInset(edge: .bottom) {
					if let playlist = chosenPlaylist ?? player.queue.currentEntry as? Playlist {
						NowPlayingView(playlist: playlist)
					}
				}
			}
			.navigationTitle("Jukebox")
			.toolbar {
				Menu {
					Picker("Sort by", selection: $sortBy) {
						Text("Date Last Played")
							.tag(PlaylistSortProperty.lastPlayedDate)
						
						Text("Date Added")
							.tag(PlaylistSortProperty.libraryAddedDate)
						
						Text("Name")
							.tag(PlaylistSortProperty.name)
					}
					
					Picker("Sort order", selection: $sortAscending) {
						Text("Ascending")
							.tag(true)
						Text("Descending")
							.tag(false)
					}
				} label: {
					Label("Sort Playlists", systemImage: "arrow.up.arrow.down.circle")
				}
			}
			.symbolRenderingMode(.hierarchical)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized {
					Task {
						await updatePlaylists()
					}
				}
			}
			.onChange(of: sortBy) {
				Task {
					await updatePlaylists()
				}
			}
			.onChange(of: sortAscending) {
				Task {
					await updatePlaylists()
				}
			}
		}
	}
	
	func fetchAllBatches<T>(_ batch: MusicItemCollection<T>) async throws -> MusicItemCollection<T> where T: MusicItem {
		var result = MusicItemCollection<T>()
		
		guard !batch.hasNextBatch else { return batch }
		guard let nextBatch = try await batch.nextBatch() else { return batch }
		result += batch
		result += try await fetchAllBatches(nextBatch)
		return result
	}
	
	func updatePlaylists() async {
		var request = MusicLibraryRequest<Playlist>()
		
		switch sortBy {
		case .lastPlayedDate:
			request.sort(by: \.lastPlayedDate, ascending: sortAscending)
		case .libraryAddedDate:
			request.sort(by: \.libraryAddedDate, ascending: sortAscending)
		case .name:
			request.sort(by: \.name, ascending: sortAscending)
		}
		
		do {
			let response = try await request.response()
			withAnimation {
				self.playlists = try await fetchAllBatches(response.items)
			}
		} catch {
			print(error)
		}
	}
	
	func playRandom() async {
		if let playlist = playlists.randomElement() {
			self.chosenPlaylist = playlist
			await playPlaylist(playlist: playlist)
		}
	}
	
	func playPlaylist(playlist: Playlist) async {
		do {
			SystemMusicPlayer.shared.queue = [playlist]
			try await SystemMusicPlayer.shared.play()
		} catch {
			print(error)
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
