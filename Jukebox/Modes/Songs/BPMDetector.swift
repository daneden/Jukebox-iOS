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
//   3. Overlap-normalized autocorrelation of the onset signal.
//   4. Score each 60–180 BPM candidate by a harmonic comb (its salience
//      plus its slower metrical harmonics) and pick the argmax — this
//      resolves the half/double/third-time octave ambiguity that a raw
//      autocorrelation peak gets wrong. Prominence over the comb-score
//      median is the confidence.
//
//  Returns nil when confidence is below a threshold (ambient,
//  classical, free-jazz) so we don't pollute the cache with values
//  we don't trust. The walk falls back to its existing similarity
//  blend for songs with no cached BPM.
//

import Accelerate
import AVFoundation
import Foundation

enum BPMDetector {
	/// Candidate BPM range. The autocorrelation of an onset train is a
	/// comb — it peaks at the true period *and* its multiples/sub-
	/// multiples — so we don't trust the raw global peak; the harmonic
	/// comb below resolves which tooth is the tap-along tempo. 60–180
	/// keeps a runaway-fast candidate from being picked (a widened ceiling
	/// let a genuinely-slow track read ~207 in validation); the comb still
	/// reads harmonics beyond 180 from the extended ACF.
	static let minBPM: Double = 60
	static let maxBPM: Double = 180

	/// Harmonic-comb weights: a true beat at lag ℓ also produces ACF peaks
	/// at 2ℓ, 3ℓ, 4ℓ (its slower metrical levels). Summing them back onto
	/// ℓ with decaying weight makes the faster, tap-along tempo win over
	/// its half/third-time aliases (Percival–Tzanetakis "enhance harmonics").
	private static let combWeights: [Float] = [1.0, 0.5, 0.5, 0.5]

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
		// period (largest lag); maxBPM gives the shortest. The comb reads
		// salience at integer multiples of each candidate lag, so the raw
		// ACF must extend to combWeights.count · maxLag.
		let minLag = Int((60.0 / maxBPM) * envelopeRate)
		let maxLag = Int((60.0 / minBPM) * envelopeRate)
		let acfMaxLag = min(centered.count - 1, combWeights.count * maxLag)
		guard minLag > 0, maxLag < centered.count, acfMaxLag >= maxLag else { return nil }

		// Overlap-normalized (unbiased) autocorrelation. Dividing each lag's
		// dot product by its overlap count n = (count − lag) removes the raw
		// dot product's structural tilt toward shorter (faster) lags.
		// `centered` is non-empty here (the envelope-length guard upstream),
		// so `baseAddress` is non-nil — force-unwrap rather than bail, which
		// would leave the scores empty and produce garbage prominence.
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

		// Harmonic comb across the candidate range: each candidate's score
		// is the (non-negative) salience at its lag plus its slower
		// metrical harmonics, so the faster tap-along tempo wins over its
		// half/third-time aliases. No tempo prior — for an energy proxy we
		// want calm music to read calm, not get pulled toward 120; and a
		// salience octave-bracket was rejected in validation (it reverted
		// the comb's correct fast picks).
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

		// Confidence: peak prominence over the median of the comb-score
		// array (post-comb, so it reflects the consolidated octave). A
		// clear-beat track peaks well above the median; ambient tracks
		// have no clear winner. /5.0 is hand-tuned — peak/median ~5 reads
		// as "obvious beat"; revisit once the re-detected cache has coverage.
		let sorted = scores.sorted()
		let median = sorted[sorted.count / 2]
		let prominence = (bestScore - median) / max(abs(median), 1e-6)
		let normalised = max(0, min(1, prominence / 5.0))

		guard normalised >= minConfidence else { return nil }

		let bpm = 60.0 / (Double(bestLag) / envelopeRate)
		return Detection(bpm: bpm, confidence: normalised)
	}
}
