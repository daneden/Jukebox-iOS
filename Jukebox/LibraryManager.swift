//
//  LibraryManager.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import Foundation
import SwiftUI
import MediaPlayer
import MusicKit

@Observable
class LibraryManager {
  static let shared = LibraryManager()
  
	let player = SystemMusicPlayer.shared
  
	var authorizationStatus: MusicAuthorization.Status = .notDetermined
  var playlists: MusicItemCollection<Playlist> = []
  
  init() {
    authorizationStatus = MusicAuthorization.currentStatus
  }
  
  func requestAuthorization() async {
		authorizationStatus = await MusicAuthorization.request()
  }
  
  func getPlaylists() async {
		let request = MusicLibraryRequest<Playlist>()
		guard let playlists = try? await request.response() else {
			return
		}
		
		self.playlists = playlists.items
  }
	
	// TODO
	func getPlaylistsContainingSong(_ song: Song) async {
		var request = MusicLibraryRequest<Playlist>()
	}
  
  func playPlaylist(playlist: Playlist, shuffle: Bool = true) async {
		try? await player.queue.insert(playlist, position: MusicPlayer.Queue.EntryInsertionPosition.afterCurrentEntry)
		try? await player.skipToNextEntry()
  }
}
