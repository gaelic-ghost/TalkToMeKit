import Foundation

struct SynthesisInput {
	let text: String?
	let textFile: String?
	let mode: SynthesisMode
	let speaker: String?
	let instruct: String?
	let language: String
	let modelID: String?
	let referenceAudio: String?
	let format: AudioFormat
}

struct BuiltSynthesisRequest {
	let path: String
	let payload: Data
}

enum SynthesisRequestBuilder {
	static func validateInput(text: String?, textFile: String?, mode: SynthesisMode, referenceAudio: String?) throws {
		if text != nil, textFile != nil {
			throw CLIError.bothTextAndFileProvided
		}
		if text == nil, textFile == nil {
			throw CLIError.missingTextInput
		}
		if mode == .voiceClone, referenceAudio == nil {
			throw CLIError.missingReferenceAudio
		}
	}

	static func resolveInputText(text: String?, textFile: String?) throws -> String {
		if let text {
			return text
		}
		guard let textFile else {
			throw CLIError.missingTextInput
		}
		do {
			return try String(contentsOfFile: textFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
		} catch {
			throw CLIError.textFileReadFailed(textFile, error)
		}
	}

	static func loadReferenceAudioBase64(path: String) throws -> String {
		do {
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			return data.base64EncodedString()
		} catch {
			throw CLIError.invalidReferenceAudioPath(path, error)
		}
	}

	static func buildRequest(from input: SynthesisInput) throws -> BuiltSynthesisRequest {
		let inputText = try resolveInputText(text: input.text, textFile: input.textFile)
		guard (1...2000).contains(inputText.count) else {
			throw CLIError.invalidTextLength(inputText.count)
		}

		let encoder = JSONEncoder()
		switch input.mode {
		case .voiceDesign:
			return .init(
				path: "/synthesize/voice-design",
				payload: try encoder.encode(
					VoiceDesignRequest(
						text: inputText,
						instruct: input.instruct ?? "A warm and clear speaking voice with natural pacing.",
						language: input.language,
						modelID: input.modelID,
						format: input.format.rawValue
					)
				)
			)
		case .customVoice:
			return .init(
				path: "/synthesize/custom-voice",
				payload: try encoder.encode(
					CustomVoiceRequest(
						text: inputText,
						speaker: input.speaker ?? "ryan",
						instruct: input.instruct,
						language: input.language,
						modelID: input.modelID,
						format: input.format.rawValue
					)
				)
			)
		case .voiceClone:
			guard let referenceAudio = input.referenceAudio else {
				throw CLIError.missingReferenceAudio
			}
			return .init(
				path: "/synthesize/voice-clone",
				payload: try encoder.encode(
					VoiceCloneRequest(
						text: inputText,
						referenceAudioB64: try loadReferenceAudioBase64(path: referenceAudio),
						language: input.language,
						modelID: input.modelID,
						format: input.format.rawValue
					)
				)
			)
		}
	}
}

protocol AudioPlayer {
	func play(audioURL: URL) throws
}

struct AfplayAudioPlayer: AudioPlayer {
	func play(audioURL: URL) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
		process.arguments = [audioURL.path]
		do {
			try process.run()
		} catch {
			throw CLIError.playbackFailed("Unable to start afplay: \(error.localizedDescription)")
		}
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CLIError.playbackFailed("afplay exited with status \(process.terminationStatus).")
		}
	}
}
