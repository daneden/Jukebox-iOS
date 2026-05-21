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
			// The spinner sits inside the label, not as an outer .overlay,
			// so glass button styles (which paint their material over outer
			// overlays) don't bury it behind the glass.
			ZStack {
				label()
					.opacity(isBusy ? 0 : 1)
				ProgressView()
					.controlSize(.small)
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
