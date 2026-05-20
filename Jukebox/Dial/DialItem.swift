//
//  DialItem.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit

/// Common surface the dial needs from any item it spins. Playlists and library
/// songs both already expose `artwork`; this protocol just names the shape so
/// `DialView` can be generic over either without reaching for a closure.
protocol DialItem {
	var artwork: Artwork? { get }
}

extension Playlist: DialItem {}
extension Song: DialItem {}
