import Foundation

struct WaveMetrics {
	let sampleRate: Int
	let channels: Int
	let bitsPerSample: Int
	let frameCount: Int
	let durationSeconds: Double
	let rms: Double
	let peak: Double
	let clippingRatio: Double
	let leadingSilenceSeconds: Double
	let trailingSilenceSeconds: Double
}

enum WaveMetricsError: Error {
	case invalidHeader
	case unsupportedFormat(audioFormat: UInt16, bitsPerSample: UInt16)
	case missingChunk(String)
	case invalidData
}

enum WaveMetricsAnalyzer {
	static func analyze(_ wav: Data, silenceThreshold: Double = 0.01) throws -> WaveMetrics {
		guard wav.count >= 44 else { throw WaveMetricsError.invalidHeader }
		guard wav[0...3] == Data("RIFF".utf8), wav[8...11] == Data("WAVE".utf8) else {
			throw WaveMetricsError.invalidHeader
		}

		var cursor = 12
		var audioFormat: UInt16?
		var channels: UInt16?
		var sampleRate: UInt32?
		var bitsPerSample: UInt16?
		var pcmData: Data?

		while cursor + 8 <= wav.count {
			let chunkID = String(decoding: wav[cursor..<(cursor + 4)], as: UTF8.self)
			let chunkSize = Int(readUInt32LE(in: wav, at: cursor + 4))
			let dataStart = cursor + 8
			let dataEnd = dataStart + chunkSize
			guard dataEnd <= wav.count else { throw WaveMetricsError.invalidData }

			if chunkID == "fmt " {
				guard chunkSize >= 16 else { throw WaveMetricsError.invalidData }
				audioFormat = readUInt16LE(in: wav, at: dataStart)
				channels = readUInt16LE(in: wav, at: dataStart + 2)
				sampleRate = readUInt32LE(in: wav, at: dataStart + 4)
				bitsPerSample = readUInt16LE(in: wav, at: dataStart + 14)
			}
			if chunkID == "data" {
				pcmData = wav[dataStart..<dataEnd]
			}

			cursor = dataEnd + (chunkSize % 2)
		}

		guard let audioFormat else { throw WaveMetricsError.missingChunk("fmt") }
		guard let channels, channels > 0 else { throw WaveMetricsError.invalidData }
		guard let sampleRate, sampleRate > 0 else { throw WaveMetricsError.invalidData }
		guard let bitsPerSample else { throw WaveMetricsError.invalidData }
		guard let pcmData else { throw WaveMetricsError.missingChunk("data") }

		let samples = try decodeSamples(
			data: pcmData,
			audioFormat: audioFormat,
			bitsPerSample: bitsPerSample,
			channels: channels
		)
		guard !samples.isEmpty else { throw WaveMetricsError.invalidData }

		let frameCount = samples.count
		let durationSeconds = Double(frameCount) / Double(sampleRate)

		var sumSquares = 0.0
		var peak = 0.0
		var clippingCount = 0
		for sample in samples {
			let magnitude = abs(sample)
			sumSquares += sample * sample
			if magnitude > peak { peak = magnitude }
			if magnitude >= 0.999 { clippingCount += 1 }
		}

		let rms = sqrt(sumSquares / Double(samples.count))
		let clippingRatio = Double(clippingCount) / Double(samples.count)
		let leadingSilence = silenceDuration(samples: samples, sampleRate: Int(sampleRate), threshold: silenceThreshold, leading: true)
		let trailingSilence = silenceDuration(samples: samples, sampleRate: Int(sampleRate), threshold: silenceThreshold, leading: false)

		return WaveMetrics(
			sampleRate: Int(sampleRate),
			channels: Int(channels),
			bitsPerSample: Int(bitsPerSample),
			frameCount: frameCount,
			durationSeconds: durationSeconds,
			rms: rms,
			peak: peak,
			clippingRatio: clippingRatio,
			leadingSilenceSeconds: leadingSilence,
			trailingSilenceSeconds: trailingSilence
		)
	}

	private static func decodeSamples(
		data: Data,
		audioFormat: UInt16,
		bitsPerSample: UInt16,
		channels: UInt16
	) throws -> [Double] {
		let channelCount = Int(channels)
		if audioFormat == 1 && bitsPerSample == 16 {
			let bytesPerSample = 2
			guard data.count % (bytesPerSample * channelCount) == 0 else { throw WaveMetricsError.invalidData }
			var result: [Double] = []
			result.reserveCapacity(data.count / (bytesPerSample * channelCount))
			data.withUnsafeBytes { rawBuffer in
				let bytes = rawBuffer.bindMemory(to: UInt8.self)
				var index = 0
				while index + (bytesPerSample * channelCount) <= bytes.count {
					let low = UInt16(bytes[index])
					let high = UInt16(bytes[index + 1])
					let packed = Int16(bitPattern: low | (high << 8))
					result.append(Double(packed) / 32768.0)
					index += bytesPerSample * channelCount
				}
			}
			return result
		}

		if audioFormat == 3 && bitsPerSample == 32 {
			let bytesPerSample = 4
			guard data.count % (bytesPerSample * channelCount) == 0 else { throw WaveMetricsError.invalidData }
			var result: [Double] = []
			result.reserveCapacity(data.count / (bytesPerSample * channelCount))
			data.withUnsafeBytes { rawBuffer in
				let bytes = rawBuffer.bindMemory(to: UInt8.self)
				var index = 0
				while index + (bytesPerSample * channelCount) <= bytes.count {
					let b0 = UInt32(bytes[index])
					let b1 = UInt32(bytes[index + 1]) << 8
					let b2 = UInt32(bytes[index + 2]) << 16
					let b3 = UInt32(bytes[index + 3]) << 24
					let bits = b0 | b1 | b2 | b3
					let value = Float(bitPattern: bits)
					result.append(Double(value))
					index += bytesPerSample * channelCount
				}
			}
			return result
		}

		throw WaveMetricsError.unsupportedFormat(audioFormat: audioFormat, bitsPerSample: bitsPerSample)
	}

	private static func silenceDuration(
		samples: [Double],
		sampleRate: Int,
		threshold: Double,
		leading: Bool
	) -> Double {
		guard sampleRate > 0 else { return 0 }
		var count = 0
		if leading {
			for sample in samples {
				if abs(sample) <= threshold {
					count += 1
				} else {
					break
				}
			}
		} else {
			for sample in samples.reversed() {
				if abs(sample) <= threshold {
					count += 1
				} else {
					break
				}
			}
		}
		return Double(count) / Double(sampleRate)
	}

	private static func readUInt16LE(in data: Data, at index: Int) -> UInt16 {
		let low = UInt16(data[index])
		let high = UInt16(data[index + 1]) << 8
		return low | high
	}

	private static func readUInt32LE(in data: Data, at index: Int) -> UInt32 {
		let b0 = UInt32(data[index])
		let b1 = UInt32(data[index + 1]) << 8
		let b2 = UInt32(data[index + 2]) << 16
		let b3 = UInt32(data[index + 3]) << 24
		return b0 | b1 | b2 | b3
	}
}
