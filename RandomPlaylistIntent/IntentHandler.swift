//
//  IntentHandler.swift
//  RandomPlaylistIntent
//
//  Created by Daniel Eden on 27/09/2021.
//

import Intents

class IntentHandler: INExtension, PlayRandomPlaylistIntentHandling {
  func resolveShuffle(for intent: PlayRandomPlaylistIntent, with completion: @escaping (INBooleanResolutionResult) -> Void) {
    guard let shuffle = intent.shuffle else {
      completion(.confirmationRequired(with: nil))
      return
    }
    
    completion(.success(with: Bool(exactly: shuffle)!))
  }
  
  override func handler(for intent: INIntent) -> Any {
    // This is the default implementation.  If you want different objects to handle different intents,
    // you can override this and return the handler you want for that particular intent.
    
    return self
  }
    
  private let libraryManager = LibraryManager.shared
  
  func handle(intent: PlayRandomPlaylistIntent, completion: @escaping (PlayRandomPlaylistIntentResponse) -> Void) {
    libraryManager.getPlaylists()
    
    if let playlist = libraryManager.playlists?.randomElement() {
      libraryManager.playPlaylist(playlist: playlist, shuffle: Bool(exactly: intent.shuffle!)!)
      
      completion(.success(playlistName: playlist.name ?? "Unnamed Playlist"))
    }
  }
}
