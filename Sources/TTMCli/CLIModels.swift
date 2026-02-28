import ArgumentParser
import Foundation

struct EndpointResponse {
	let statusCode: Int
	let body: String
}

struct SynthesizeResult {
	let audioData: Data
	let sampleRate: Int?
}

enum CLIError: LocalizedError {
	case invalidBaseURL(String)
	case invalidTextLength(Int)
	case invalidReferenceAudioPath(String, Error)
	case missingTextInput
	case bothTextAndFileProvided
	case missingReferenceAudio
	case requestFailed(String)
	case unexpectedStatus(Int, String)
	case invalidResponse(String)
	case writeFailed(String, Error)
	case playbackFailed(String)
	case textFileReadFailed(String, Error)

	var errorDescription: String? {
		switch self {
		case .invalidBaseURL(let value):
			"Invalid base URL: \(value)"
		case .invalidTextLength(let length):
			"Text must be 1...2000 characters, got \(length)."
		case .invalidReferenceAudioPath(let path, let error):
			"Failed to read reference audio at \(path): \(error.localizedDescription)"
		case .missingTextInput:
			"Missing text input. Provide --text or --text-file."
		case .bothTextAndFileProvided:
			"Use either --text or --text-file, not both."
		case .missingReferenceAudio:
			"--reference-audio is required for voice-clone mode."
		case .requestFailed(let message):
			"Request failed: \(message)"
		case .unexpectedStatus(let code, let body):
			body.isEmpty ? "Server returned status \(code)." : "Server returned status \(code): \(body)"
		case .invalidResponse(let message):
			"Invalid response: \(message)"
		case .writeFailed(let path, let error):
			"Failed to write output at \(path): \(error.localizedDescription)"
		case .playbackFailed(let message):
			"Playback failed: \(message)"
		case .textFileReadFailed(let path, let error):
			"Failed to read text file at \(path): \(error.localizedDescription)"
		}
	}
}

enum AudioFormat: String, ExpressibleByArgument {
	case wav
}

enum SynthesisMode: String, ExpressibleByArgument {
	case voiceDesign = "voice-design"
	case customVoice = "custom-voice"
	case voiceClone = "voice-clone"
}

enum ModelMode: String, ExpressibleByArgument {
	case voiceDesign = "voice_design"
	case customVoice = "custom_voice"
	case voiceClone = "voice_clone"
}

struct ModelLoadRequest: Codable {
	let mode: String
	let modelID: String?
	let strictLoad: Bool?

	enum CodingKeys: String, CodingKey {
		case mode
		case modelID = "model_id"
		case strictLoad = "strict_load"
	}
}

struct VoiceDesignRequest: Codable {
	let text: String
	let instruct: String
	let language: String
	let modelID: String?
	let format: String

	enum CodingKeys: String, CodingKey {
		case text
		case instruct
		case language
		case modelID = "model_id"
		case format
	}
}

struct CustomVoiceRequest: Codable {
	let text: String
	let speaker: String
	let instruct: String?
	let language: String
	let modelID: String?
	let format: String

	enum CodingKeys: String, CodingKey {
		case text
		case speaker
		case instruct
		case language
		case modelID = "model_id"
		case format
	}
}

struct VoiceCloneRequest: Codable {
	let text: String
	let referenceAudioB64: String
	let language: String
	let modelID: String?
	let format: String

	enum CodingKeys: String, CodingKey {
		case text
		case referenceAudioB64 = "reference_audio_b64"
		case language
		case modelID = "model_id"
		case format
	}
}

func decodeJSONOrString(_ text: String) -> Any {
	guard let data = text.data(using: .utf8), !text.isEmpty else {
		return ""
	}
	if let value = try? JSONSerialization.jsonObject(with: data) {
		return value
	}
	return text
}

func printJSONObject(_ object: [String: Any]) {
	guard JSONSerialization.isValidJSONObject(object),
		  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
		  let text = String(data: data, encoding: .utf8) else {
		print("{\"ok\":true}")
		return
	}
	print(text)
}

func printEndpointResult(endpoint: String, response: EndpointResponse, json: Bool, fallback: String) {
	if json {
		let payload: [String: Any] = [
			"ok": true,
			"endpoint": endpoint,
			"statusCode": response.statusCode,
			"body": decodeJSONOrString(response.body),
		]
		printJSONObject(payload)
		return
	}
	print(response.body.isEmpty ? fallback : response.body)
}
