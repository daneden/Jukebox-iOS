//
//  AsyncButton.swift
//  Jukebox
//
//  Created by Daniel Eden on 03/07/2023.
//

import SwiftUI

struct AsyncButton<T: View>: View {
	@State private var isBusy = false
	var action: () async -> Void
	var label: () -> T

	var body: some View {
		Button {
			Task {
				isBusy = true
				await action()
				isBusy = false
			}
		} label: {
			// Spinner inside the label, not an outer .overlay — glass styles
			// paint their material over outer overlays and would bury it.
			ZStack {
				label()
					.opacity(isBusy ? 0 : 1)
				ProgressView()
				#if os(macOS)
					.controlSize(.small)
				#else
					.controlSize(.regular)
				#endif
					.opacity(isBusy ? 1 : 0)
			}
		}
		.disabled(isBusy)
	}
}

#Preview {
	AsyncButton {
		try? await Task.sleep(nanoseconds: 1_000_000_000)
	} label: {
		Text("Run async code")
	}
	.buttonStyle(.borderedProminent)
}
