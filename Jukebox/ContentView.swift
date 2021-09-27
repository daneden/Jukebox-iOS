//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import SwiftUI
import MediaPlayer

struct ContentView: View {
  @ObservedObject private var libraryManager = LibraryManager.shared
  private let player = LibraryManager.shared.player
  
  @State private var chosenPlaylist: MPMediaPlaylist?
  @State private var shuffle = true
  
  var item: MPMediaItem? {
    player.nowPlayingItem
  }
  
  var body: some View {
    NavigationView {
      List {
        Section {
          VStack(alignment: .leading) {
            Text("Jukebox is a utility app that does one thing: pick a random playlist from your Apple Music library and play it.")
              .padding(.bottom)
              .fixedSize(horizontal: false, vertical: true)
            
            Text("Jukebox is designed to be used with Siri and/or Shortcuts, but can also be used as a standalone app to simply play a random playlist.")
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical)
        } header: {
          Text("About Jukebox")
        }
        
        Section {
          Button(action: { playRandom() }) {
            Label("Play Random Playlist", systemImage: "music.note.list")
          }
          
          Toggle(isOn: $shuffle) {
            Label("Shuffle Songs \(shuffle ? "On" : "Off")", systemImage: "shuffle")
          }
        }
        
        if let playlist = chosenPlaylist {
          Section {
            HStack(alignment: .top) {
              Text(playlist.name ?? "Unnamed Playlist").font(.headline)
              Spacer()
              Text("\(playlist.count) songs").foregroundColor(.secondary)
            }
            
            Link(destination: URL(string: "music://music.apple.com/playlist/id\(playlist.cloudGlobalID!)")!) {
              Label("Open in Music", systemImage: "music.note")
            }
          } header: {
            Text("Chosen playlist")
          }
        }
      }
      .navigationTitle("Jukebox")
      .transition(.slide)
      .symbolRenderingMode(.hierarchical)
      .onAppear {
        libraryManager.getPlaylists()
      }
    }
  }
  
  func playRandom() {
    DispatchQueue.main.async {
      if let playlist = libraryManager.playlists?.randomElement() {
        self.chosenPlaylist = playlist
        playPlaylist(playlist: playlist)
      }
    }
  }
  
  func playPlaylist(playlist: MPMediaPlaylist) {
    player.setQueue(with: playlist)
    player.shuffleMode = shuffle ? .songs : .off
    player.play()
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
