//
//  BPMDetector.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Single-pass BPM detection from a 30s audio preview. Designed to
//  run alongside `AudioFeaturePrint` in `AudioEmbeddingService` —
//  the song-similarity embedding captures *timbre*; this captures
//  *rhythm*, which the walk uses as a complementary similarity
//  signal so 80 BPM ballads don't sit next to 160 BPM dance tracks
//  with similar timbres.
//
//  Algorithm (deliberately simple — popular-music coverage matters
//  more than perfect accuracy on free-time / ambient tracks):
//   1. Mix to mono, accumulate a per-frame RMS energy envelope at
//      ~10ms hops.
//   2. Half-wave-rectified differential → onset signal.
//   3. Autocorrelate the onset signal at lags corresponding to the
//      60–180 BPM range.
//   4. Pick the peak; normalised peak prominence is the confidence.
//
//  Returns nil when confidence is below a threshold (ambient,
//  classical, free-jazz) so we don't pollute the cache with values
//  we don't trust. The walk falls back to its existing similarity
//  blend for songs with no cached BPM.
//

import AVFoundation
import Accelerate
import Foundation

enum BPMDetector {
	/// BPM range we'll detect. Below 60, popular music is usually
	/// the half-time perception of a 120 BPM beat; above 180 is the
	/// double-time perception. The autocorrelation naturally picks
	/// the most-energetic period in this range, which matches what
	/// a listener would tap along to.
	static let minBPM: Double = 60
	static let maxBPM: Double = 180

	/// Hop size for the energy envelope. ~10ms at 44.1kHz resolves
	/// closely-spaced kick-drum hits without smoothing them into a
	/// single onset.
	static let envelopeHopSize = 441

	/// Confidence floor below which we report nil. Tuned by ear; the
	/// walk treats missing BPM as "no signal" rather than penalising
	/// the song, so erring on the side of nil is cheaper than
	/// committing to a wrong value.
	static let minConfidence: Float = 0.3

	struct Detection {
		let bpm: Double
		let confidence: Float
	}

	static func detect(audioFileURL: URL) -> Detection? {
		guard let file = try? AVAudioFile(forReading: audioFileURL) else { return nil }
		let format = file.processingFormat
		let frameCount = AVAudioFrameCount(file.length)
		guard frameCount > 0,
		      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
		else {
			return nil
		}
		do {
			try file.read(into: buffer)
		} catch {
			return nil
		}

		let envelope = energyEnvelope(buffer)
		guard envelope.count > 32 else { return nil }

		let onset = halfWaveRectifiedDiff(envelope)
		let envelopeRate = format.sampleRate / Double(envelopeHopSize)
		return tempoFromOnset(onset, envelopeRate: envelopeRate)
	}

	private static func energyEnvelope(_ buffer: AVAudioPCMBuffer) -> [Float] {
		guard let channelData = buffer.floatChannelData else { return [] }
		let frameLength = Int(buffer.frameLength)
		let channels = Int(buffer.format.channelCount)
		let hop = envelopeHopSize
		let frames = frameLength / hop

		var envelope = [Float](repeating: 0, count: frames)
		for f in 0 ..< frames {
			let start = f * hop
			var sum: Float = 0
			for ch in 0 ..< channels {
				var rms: Float = 0
				vDSP_rmsqv(channelData[ch].advanced(by: start), 1, &rms, vDSP_Length(hop))
				sum += rms
			}
			envelope[f] = sum / Float(channels)
		}
		return envelope
	}

	private static func halfWaveRectifiedDiff(_ envelope: [Float]) -> [Float] {
		var out = [Float](repeating: 0, count: envelope.count)
		for i in 1 ..< envelope.count {
			out[i] = max(0, envelope[i] - envelope[i - 1])
		}
		return out
	}

	private static func tempoFromOnset(_ onset: [Float], envelopeRate: Double) -> Detection? {
		// Center the signal so autocorrelation isn't dominated by DC.
		var mean: Float = 0
		vDSP_meanv(onset, 1, &mean, vDSP_Length(onset.count))
		let centered = onset.map { $0 - mean }

		// BPM → lag (in envelope samples). minBPM gives the longest
		// period (largest lag); maxBPM gives the shortest.
		let minLag = Int((60.0 / maxBPM) * envelopeRate)
		let maxLag = Int((60.0 / minBPM) * envelopeRate)
		guard minLag > 0, maxLag < centered.count else { return nil }

		// Brute-force autocorrelation across the lag range. ~70 lags
		// at typical envelope rates — bounded; no point bringing FFT
		// machinery in for this.
		var bestLag = minLag
		var bestValue: Float = -.infinity
		var values = [Float](repeating: 0, count: maxLag - minLag + 1)
		// `centered` is non-empty here (we returned early upstream if
		// the envelope was too short), so `baseAddress` is guaranteed
		// non-nil — force-unwrap rather than guard-and-return-nil,
		// which would leave `bestValue` at -.infinity and produce
		// garbage prominence below.
		centered.withUnsafeBufferPointer { ptr in
			let base = ptr.baseAddress!
			for (idx, lag) in (minLag ... maxLag).enumerated() {
				var v: Float = 0
				let n = centered.count - lag
				vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &v, vDSP_Length(n))
				values[idx] = v
				if v > bestValue {
					bestValue = v
					bestLag = lag
				}
			}
		}

		// Confidence: peak prominence over the median of the
		// autocorrelation across the search range. A clear-beat
		// track has a sharp peak well above the median; ambient
		// tracks have noisy autocorrelation with no clear winner.
		let sorted = values.sorted()
		let median = sorted[sorted.count / 2]
		let prominence = (bestValue - median) / max(abs(median), 1e-6)
		// /5.0 is a hand-tuned scaling — peak/median ratios of ~5
		// empirically correspond to "obvious beat." Revisit after
		// the cache has coverage.
		let normalised = max(0, min(1, prominence / 5.0))

		guard normalised >= minConfidence else { return nil }

		let bpm = 60.0 / (Double(bestLag) / envelopeRate)
		return Detection(bpm: bpm, confidence: normalised)
	}
}
