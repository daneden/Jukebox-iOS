//
//  AudioRouteSession.swift
//  Jukebox
//
//  SystemMusicPlayer renders audio out of process, so the in-app AirPlay picker
//  (bound to *our* audio session) can't reach it by default. `.longFormAudio`
//  route sharing exists to "play to the same output as the built-in Music and
//  Podcast apps" — activating it is the one documented lever that might bind our
//  session's route, and thus the picker, to Music's output. Undocumented for
//  SystemMusicPlayer; only a real-device test with an AirPlay speaker proves it.
//

#if os(iOS)
	import AVFoundation
	import OSLog

	enum AudioRouteSession {
		private static let log = Logger(subsystem: "me.daneden.Jukebox", category: "AudioRoute")
		private static var activated = false

		static func prepareForLongFormPlayback() {
			guard !activated else { return }
			let session = AVAudioSession.sharedInstance()
			do {
				try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
				try session.setActive(true)
				activated = true
			} catch {
				log.error("longForm session setup failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
#endif
