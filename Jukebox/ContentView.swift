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
			List {
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
						ForEach(playlists) { playlist in
							PlaylistRowView(playlist: playlist)
						}
					default:
						Text("Something went wrong")
					}
			}
			.listStyle(.plain)
			.dataTask {
				await updatePlaylists()
			}
			.safeAreaInset(edge: .bottom) {
				HStack(spacing: 4) {
					if let playlist = chosenPlaylist {
						NowPlayingView(playlist: playlist)
					}
					
					Button {
						Task { await playRandom() }
					} label: {
						Label("Play Random Playlist", systemImage: "shuffle")
							.frame(maxWidth: chosenPlaylist == nil ? .infinity : nil)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.extraLarge)
					.disabled(playlists.isEmpty)
					.buttonBorderShape(chosenPlaylist == nil ? .automatic : .circle)
				}
				.scenePadding()
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
			.overlay {
				if playlists.isEmpty && MusicAuthorization.currentStatus == .authorized {
					VStack {
						Spacer()
						Text("No Playlists")
							.foregroundStyle(.secondary)
						Spacer()
					}
					.transition(.opacity.combined(with: .scale))
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
				Task { self.playlists = try await fetchAllBatches(response.items) }
			}
		} catch {
			print(error)
		}
	}
	
	func playRandom() async {
		if let playlist = playlists.randomElement(),
			 let detailedPlaylist = try? await playlist.with([.tracks]) {
			withAnimation {
				self.chosenPlaylist = detailedPlaylist
			}
			await playPlaylist(playlist: detailedPlaylist)
		}
	}
	
	func playPlaylist(playlist: Playlist) async {
		do {
			SystemMusicPlayer.shared.queue = [playlist]
			try await SystemMusicPlayer.shared.play()
			await updatePlaylists()
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
