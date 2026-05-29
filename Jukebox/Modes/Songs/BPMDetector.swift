//
//  BPMDetector.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Single-pass BPM detection from a 30s preview, complementing the
//  AudioFeaturePrint *timbre* embedding with *rhythm* so 80 BPM
//  ballads don't sit next to 160 BPM dance tracks of similar timbre.
//
//  Algorithm (deliberately simple — popular-music coverage over
//  accuracy on free-time/ambient):
//   1. Mono RMS energy envelope at ~10ms hops.
//   2. Half-wave-rectified differential → onset signal.
//   3. Overlap-normalized autocorrelation of the onset signal.
//   4. Score each 60–180 BPM candidate by a harmonic comb and take
//      the argmax — resolves the half/double/third-time octave
//      ambiguity a raw ACF peak gets wrong. Confidence = prominence
//      over the comb-score median.
//
//  Returns nil below a confidence threshold (ambient, classical,
//  free-jazz) rather than cache an untrusted value.
//

import Accelerate
import AVFoundation
import Foundation

enum BPMDetector {
	/// Candidate BPM range. 60–180 keeps a runaway-fast candidate from
	/// winning (a widened ceiling let a genuinely-slow track read ~207
	/// in validation); the comb still reads harmonics beyond 180.
	static let minBPM: Double = 60
	static let maxBPM: Double = 180

	/// Harmonic-comb weights: a true beat at lag ℓ also peaks at 2ℓ, 3ℓ,
	/// 4ℓ. Summing them back onto ℓ with decaying weight makes the faster
	/// tap-along tempo win over its half/third-time aliases
	/// (Percival–Tzanetakis "enhance harmonics").
	private static let combWeights: [Float] = [1.0, 0.5, 0.5, 0.5]

	/// Energy-envelope hop. ~10ms at 44.1kHz resolves closely-spaced
	/// kick-drum hits without smoothing them into a single onset.
	static let envelopeHopSize = 441

	/// Confidence floor below which we report nil. The walk treats
	/// missing BPM as "no signal", so nil is cheaper than a wrong value.
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

		// BPM → lag (envelope samples). The comb reads multiples of each
		// candidate lag, so the ACF must extend to combWeights.count · maxLag.
		let minLag = Int((60.0 / maxBPM) * envelopeRate)
		let maxLag = Int((60.0 / minBPM) * envelopeRate)
		let acfMaxLag = min(centered.count - 1, combWeights.count * maxLag)
		guard minLag > 0, maxLag < centered.count, acfMaxLag >= maxLag else { return nil }

		// Overlap-normalized autocorrelation: dividing each lag's dot
		// product by its overlap count n removes the structural tilt
		// toward shorter (faster) lags. `centered` is non-empty (guard
		// upstream), so the force-unwrap is safe.
		var r = [Float](repeating: 0, count: acfMaxLag + 1)
		centered.withUnsafeBufferPointer { ptr in
			let base = ptr.baseAddress!
			for lag in 1 ... acfMaxLag {
				var dot: Float = 0
				let n = centered.count - lag
				vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &dot, vDSP_Length(n))
				r[lag] = dot / Float(n)
			}
		}

		// Harmonic comb: salience at each lag plus its slower harmonics,
		// so the faster tap-along tempo wins over half/third-time aliases.
		// No tempo prior — for an energy proxy, calm music should read
		// calm, not get pulled toward 120 (an octave-bracket was tried and
		// reverted the comb's correct fast picks).
		var bestLag = minLag
		var bestScore: Float = -.infinity
		var scores = [Float](repeating: 0, count: maxLag - minLag + 1)
		for (idx, lag) in (minLag ... maxLag).enumerated() {
			var s: Float = 0
			for k in 1 ... combWeights.count {
				let kl = k * lag
				if kl <= acfMaxLag { s += combWeights[k - 1] * max(0, r[kl]) }
			}
			scores[idx] = s
			if s > bestScore {
				bestScore = s
				bestLag = lag
			}
		}

		// Confidence: peak prominence over the comb-score median. Clear-beat
		// tracks peak well above it; ambient tracks have no clear winner.
		// /5.0 is hand-tuned — peak/median ~5 reads as "obvious beat".
		let sorted = scores.sorted()
		let median = sorted[sorted.count / 2]
		let prominence = (bestScore - median) / max(abs(median), 1e-6)
		let normalised = max(0, min(1, prominence / 5.0))

		guard normalised >= minConfidence else { return nil }

		let bpm = 60.0 / (Double(bestLag) / envelopeRate)
		return Detection(bpm: bpm, confidence: normalised)
	}
}
