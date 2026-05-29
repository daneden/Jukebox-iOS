//
//  DialItem.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit

/// Common surface the dial needs from any item it spins, so `DialView` can be generic over Playlist or Song.
protocol DialItem {
	var artwork: Artwork? { get }
}

extension Playlist: DialItem {}
extension Song: DialItem {}
