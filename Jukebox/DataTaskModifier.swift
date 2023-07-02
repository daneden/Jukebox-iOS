//
//  DataTaskModifier.swift
//  Jukebox
//
//  Created by Daniel Eden on 02/07/2023.
//

import SwiftUI

struct DataTaskModifier: ViewModifier {
	@Environment(\.scenePhase) private var scenePhase
	var action: () async -> Void
	
	func body(content: Content) -> some View {
		content
			.task {
				await action()
			}
			.onChange(of: scenePhase) { _, newValue in
				if newValue == .active {
					Task {
						await action()
					}
				}
			}
			.refreshable {
				await action()
			}
	}
}

extension View {
	func dataTask(_ action: @escaping () async -> Void) -> some View {
		return self.modifier(DataTaskModifier(action: action))
	}
}
