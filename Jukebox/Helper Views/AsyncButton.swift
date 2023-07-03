//
//  AsyncButton.swift
//  Jukebox
//
//  Created by Daniel Eden on 03/07/2023.
//

import SwiftUI

struct AsyncButton<T>: View where T: View {
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
			label()
				.opacity(isBusy ? 0 : 1)
		}
		.disabled(isBusy)
		.overlay {
			if isBusy {
				ProgressView()
					.controlSize(.regular)
			}
		}
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
