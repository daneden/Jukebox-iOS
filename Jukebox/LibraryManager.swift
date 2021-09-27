//
//  LibraryManager.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import Foundation
import Combine
import MediaPlayer

class LibraryManager: ObservableObject {
  static let shared = LibraryManager()
  
  let player = MPMusicPlayerController.systemMusicPlayer
  
  @Published var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
  @Published var playlists: [MPMediaPlaylist]?
  
  init() {
    authorizationStatus = MPMediaLibrary.authorizationStatus()
  }
  
  func requestAuthorization() async {
    authorizationStatus = await MPMediaLibrary.requestAuthorization()
  }
  
  func getPlaylists() {
    if let playlists = MPMediaQuery.playlists().collections as? [MPMediaPlaylist] {
      self.playlists = playlists.filter { $0.count > 0 }
    }
  }
  
  func playPlaylist(playlist: MPMediaPlaylist, shuffle: Bool = true) {
    player.setQueue(with: playlist)
    player.shuffleMode = shuffle ? .songs : .off
    player.play()
  }
}
