//
//  WidgetsBundle.swift
//  Widgets
//
//  Created by Daniel Eden on 30/05/2026.
//

import SwiftUI
import WidgetKit

@main
struct WidgetsBundle: WidgetBundle {
	var body: some Widget {
		PlayRandomPlaylistControl()
		MakeGemsControl()
	}
}
