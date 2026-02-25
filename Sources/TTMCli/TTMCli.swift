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

struct GlobalOptions: ParsableArguments {
	@Option(name: .customLong("base-url"), help: "Base URL of the TalkToMe server.")
	var baseURL: String = "http://127.0.0.1:8080"

	@Option(name: .long, help: "Request timeout in seconds.")
	var timeout: Double = 30

	@Flag(help: "Enable verbose request/response logging.")
	var verbose: Bool = false

	func makeClient() throws -> TTMClient {
		guard let url = URL(string: baseURL) else {
			throw CLIError.invalidBaseURL(baseURL)
		}
		return TTMClient(baseURL: url, timeout: timeout, verbose: verbose)
	}
}

struct TTMClient {
	private let baseURL: URL
	private let timeout: Double
	private let verbose: Bool
	private let session: URLSession

	init(baseURL: URL, timeout: Double, verbose: Bool, session: URLSession = .shared) {
		self.baseURL = baseURL
		self.timeout = timeout
		self.verbose = verbose
		self.session = session
	}

	func health() async throws -> EndpointResponse {
		try await requestJSON(path: "/health", method: "GET")
	}

	func version() async throws -> EndpointResponse {
		try await requestJSON(path: "/version", method: "GET")
	}

	func adapters() async throws -> EndpointResponse {
		try await requestJSON(path: "/adapters", method: "GET")
	}

	func adapterStatus(adapterID: String) async throws -> EndpointResponse {
		try await requestJSON(path: "/adapters/\(adapterID)/status", method: "GET")
	}

	func status() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/status", method: "GET")
	}

	func inventory() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/inventory", method: "GET")
	}

	func unload() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/unload", method: "POST")
	}

	func customVoiceSpeakers(modelID: String?) async throws -> EndpointResponse {
		var path = "/custom-voice/speakers"
		if let modelID, !modelID.isEmpty {
			let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelID
			path += "?model_id=\(encoded)"
		}
		return try await requestJSON(path: path, method: "GET")
	}

	func load(request: ModelLoadRequest) async throws -> EndpointResponse {
		let payload = try JSONEncoder().encode(request)
		let (response, data) = try await send(path: "/model/load", method: "POST", contentType: "application/json", body: payload)
		guard response.statusCode == 200 || response.statusCode == 202 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		return EndpointResponse(statusCode: response.statusCode, body: decodeBody(data))
	}

	func synthesize(path: String, payload: Data) async throws -> SynthesizeResult {
		let (response, data) = try await send(path: path, method: "POST", contentType: "application/json", body: payload)
		guard response.statusCode == 200 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		let mimeType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
		guard mimeType.lowercased().contains("audio/wav") else {
			throw CLIError.invalidResponse("Expected audio/wav content type, got '\(mimeType)'.")
		}
		let sampleRate = response.value(forHTTPHeaderField: "X-Sample-Rate").flatMap(Int.init)
		return .init(audioData: data, sampleRate: sampleRate)
	}

	private func requestJSON(path: String, method: String) async throws -> EndpointResponse {
		let (response, data) = try await send(path: path, method: method)
		guard response.statusCode == 200 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		return .init(statusCode: response.statusCode, body: decodeBody(data))
	}

	private func send(path: String, method: String, contentType: String? = nil, body: Data? = nil) async throws -> (HTTPURLResponse, Data) {
		guard let url = URL(string: path, relativeTo: baseURL) else {
			throw CLIError.invalidResponse("Failed to build URL from path \(path).")
		}

		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		request.httpBody = body
		if let contentType {
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		}

		if verbose {
			writeToStderr("-> \(method) \(url.absoluteString)\n")
		}

		do {
			let (data, response) = try await session.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse else {
				throw CLIError.invalidResponse("Non-HTTP response.")
			}
			if verbose {
				writeToStderr("<- \(httpResponse.statusCode) \(url.absoluteString) (\(data.count) bytes)\n")
			}
			return (httpResponse, data)
		} catch {
			throw CLIError.requestFailed(error.localizedDescription)
		}
	}

	private func decodeBody(_ data: Data) -> String {
		String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	}

	private func writeToStderr(_ message: String) {
		guard let data = message.data(using: .utf8) else { return }
		FileHandle.standardError.write(data)
	}
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

@main
struct TTMCliMain: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "ttm-cli",
		abstract: "CLI client for TalkToMeKit server APIs.",
		subcommands: [
			Health.self,
			Version.self,
			Status.self,
			Inventory.self,
			Adapters.self,
			AdapterStatus.self,
			Load.self,
			Unload.self,
			Speakers.self,
			Synthesize.self,
			Play.self,
		]
	)

	mutating func run() async throws {
		throw CleanExit.helpRequest(self)
	}
}

struct Health: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "health", abstract: "Check service health.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().health()
		printEndpointResult(endpoint: "/health", response: response, json: json, fallback: "healthy")
	}
}

struct Version: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "version", abstract: "Get service/API version.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().version()
		printEndpointResult(endpoint: "/version", response: response, json: json, fallback: "ok")
	}
}

struct Status: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "status", abstract: "Get model status.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().status()
		printEndpointResult(endpoint: "/model/status", response: response, json: json, fallback: "ok")
	}
}

struct Inventory: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "inventory", abstract: "Get model inventory.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().inventory()
		printEndpointResult(endpoint: "/model/inventory", response: response, json: json, fallback: "ok")
	}
}

struct Adapters: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "adapters", abstract: "List adapters.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().adapters()
		printEndpointResult(endpoint: "/adapters", response: response, json: json, fallback: "ok")
	}
}

struct AdapterStatus: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "adapter-status", abstract: "Get adapter status.")
	@OptionGroup var global: GlobalOptions
	@Argument(help: "Adapter id, for example qwen3-tts.")
	var adapterID: String
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().adapterStatus(adapterID: adapterID)
		printEndpointResult(endpoint: "/adapters/\(adapterID)/status", response: response, json: json, fallback: "ok")
	}
}

struct Load: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "load", abstract: "Load a model/mode.")
	@OptionGroup var global: GlobalOptions
	@Option(help: "Mode: voice_design | custom_voice | voice_clone.")
	var mode: ModelMode
	@Option(name: .customLong("model-id"), help: "Optional model id override.")
	var modelID: String?
	@Flag(name: .customLong("strict-load"), help: "Require the exact requested model without fallback.")
	var strictLoad: Bool = false
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let request = ModelLoadRequest(mode: mode.rawValue, modelID: modelID, strictLoad: strictLoad ? true : nil)
		let response = try await global.makeClient().load(request: request)
		printEndpointResult(endpoint: "/model/load", response: response, json: json, fallback: "ok")
	}
}

struct Unload: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "unload", abstract: "Unload current model.")
	@OptionGroup var global: GlobalOptions
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().unload()
		printEndpointResult(endpoint: "/model/unload", response: response, json: json, fallback: "ok")
	}
}

struct Speakers: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "speakers", abstract: "List custom-voice speakers.")
	@OptionGroup var global: GlobalOptions
	@Option(name: .customLong("model-id"), help: "Optional custom_voice model id.")
	var modelID: String?
	@Flag(help: "Output result as JSON envelope.")
	var json: Bool = false

	mutating func run() async throws {
		let response = try await global.makeClient().customVoiceSpeakers(modelID: modelID)
		printEndpointResult(endpoint: "/custom-voice/speakers", response: response, json: json, fallback: "ok")
	}
}

struct Synthesize: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "synthesize", abstract: "Synthesize text to WAV.")
	@Option(help: "Input text to synthesize.")
	var text: String?
	@Option(name: .customLong("text-file"), help: "Path to a UTF-8 text file.")
	var textFile: String?
	@Option(name: .customLong("mode"), help: "Synthesis mode endpoint.")
	var mode: SynthesisMode = .voiceDesign
	@Option(name: .customLong("speaker"), help: "Speaker for custom-voice.")
	var speaker: String?
	@Option(name: .customLong("instruct"), help: "Instruction text.")
	var instruct: String?
	@Option(name: .customLong("language"), help: "Language string.")
	var language: String = "English"
	@Option(name: .customLong("model-id"), help: "Optional model id.")
	var modelID: String?
	@Option(name: .customLong("reference-audio"), help: "Path to reference WAV for voice-clone mode.")
	var referenceAudio: String?
	@Option(help: "Output format.")
	var format: AudioFormat = .wav
	@Option(name: [.short, .long], help: "Output WAV path.")
	var output: String = "output.wav"
	@Flag(name: .customLong("print-sample-rate"), help: "Print X-Sample-Rate header when present.")
	var printSampleRate: Bool = false
	@OptionGroup var global: GlobalOptions

	mutating func validate() throws {
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

	mutating func run() async throws {
		let inputText = try resolveInputText()
		guard (1...2000).contains(inputText.count) else {
			throw CLIError.invalidTextLength(inputText.count)
		}

		let encoder = JSONEncoder()
		let path: String
		let payload: Data
		switch mode {
		case .voiceDesign:
			path = "/synthesize/voice-design"
			let request = VoiceDesignRequest(
				text: inputText,
				instruct: instruct ?? "A warm and clear speaking voice with natural pacing.",
				language: language,
				modelID: modelID,
				format: format.rawValue
			)
			payload = try encoder.encode(request)
		case .customVoice:
			path = "/synthesize/custom-voice"
			let request = CustomVoiceRequest(
				text: inputText,
				speaker: speaker ?? "ryan",
				instruct: instruct,
				language: language,
				modelID: modelID,
				format: format.rawValue
			)
			payload = try encoder.encode(request)
		case .voiceClone:
			path = "/synthesize/voice-clone"
			let reference = try loadReferenceAudioBase64(path: referenceAudio!)
			let request = VoiceCloneRequest(
				text: inputText,
				referenceAudioB64: reference,
				language: language,
				modelID: modelID,
				format: format.rawValue
			)
			payload = try encoder.encode(request)
		}

		let result = try await global.makeClient().synthesize(path: path, payload: payload)
		let outputURL = URL(fileURLWithPath: output)
		do {
			try result.audioData.write(to: outputURL, options: .atomic)
		} catch {
			throw CLIError.writeFailed(output, error)
		}
		print("Wrote \(result.audioData.count) bytes to \(outputURL.path)")
		if printSampleRate, let sampleRate = result.sampleRate {
			print("Sample rate: \(sampleRate)")
		}
	}

	private func resolveInputText() throws -> String {
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

	private func loadReferenceAudioBase64(path: String) throws -> String {
		do {
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			return data.base64EncodedString()
		} catch {
			throw CLIError.invalidReferenceAudioPath(path, error)
		}
	}
}

struct Play: AsyncParsableCommand {
	static let configuration = CommandConfiguration(commandName: "play", abstract: "Synthesize text and play it immediately.")
	@Option(help: "Input text to synthesize.")
	var text: String?
	@Option(name: .customLong("text-file"), help: "Path to a UTF-8 text file.")
	var textFile: String?
	@Option(name: .customLong("mode"), help: "Synthesis mode endpoint.")
	var mode: SynthesisMode = .voiceDesign
	@Option(name: .customLong("speaker"), help: "Speaker for custom-voice.")
	var speaker: String?
	@Option(name: .customLong("instruct"), help: "Instruction text.")
	var instruct: String?
	@Option(name: .customLong("language"), help: "Language string.")
	var language: String = "English"
	@Option(name: .customLong("model-id"), help: "Optional model id.")
	var modelID: String?
	@Option(name: .customLong("reference-audio"), help: "Path to reference WAV for voice-clone mode.")
	var referenceAudio: String?
	@Option(help: "Output format.")
	var format: AudioFormat = .wav
	@Flag(name: .customLong("print-sample-rate"), help: "Print X-Sample-Rate header when present.")
	var printSampleRate: Bool = false
	@Option(name: .customLong("keep-temp"), help: "Optional path to keep a WAV copy.")
	var keepTemp: String?
	@OptionGroup var global: GlobalOptions

	mutating func validate() throws {
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

	mutating func run() async throws {
		let inputText = try resolveInputText()
		guard (1...2000).contains(inputText.count) else {
			throw CLIError.invalidTextLength(inputText.count)
		}

		let encoder = JSONEncoder()
		let path: String
		let payload: Data
		switch mode {
		case .voiceDesign:
			path = "/synthesize/voice-design"
			payload = try encoder.encode(
				VoiceDesignRequest(
					text: inputText,
					instruct: instruct ?? "A warm and clear speaking voice with natural pacing.",
					language: language,
					modelID: modelID,
					format: format.rawValue
				)
			)
		case .customVoice:
			path = "/synthesize/custom-voice"
			payload = try encoder.encode(
				CustomVoiceRequest(
					text: inputText,
					speaker: speaker ?? "ryan",
					instruct: instruct,
					language: language,
					modelID: modelID,
					format: format.rawValue
				)
			)
		case .voiceClone:
			path = "/synthesize/voice-clone"
			payload = try encoder.encode(
				VoiceCloneRequest(
					text: inputText,
					referenceAudioB64: try loadReferenceAudioBase64(path: referenceAudio!),
					language: language,
					modelID: modelID,
					format: format.rawValue
				)
			)
		}

		let result = try await global.makeClient().synthesize(path: path, payload: payload)
		if printSampleRate, let sampleRate = result.sampleRate {
			print("Sample rate: \(sampleRate)")
		}

		let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ttm-cli-\(UUID().uuidString).wav")
		do {
			try result.audioData.write(to: tempURL, options: .atomic)
		} catch {
			throw CLIError.writeFailed(tempURL.path, error)
		}

		if let keepTemp {
			let keepURL = URL(fileURLWithPath: keepTemp)
			do {
				try result.audioData.write(to: keepURL, options: .atomic)
				print("Saved copy to \(keepURL.path)")
			} catch {
				throw CLIError.writeFailed(keepURL.path, error)
			}
		}

		defer { try? FileManager.default.removeItem(at: tempURL) }
		try playAudio(at: tempURL)
	}

	private func resolveInputText() throws -> String {
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

	private func loadReferenceAudioBase64(path: String) throws -> String {
		do {
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			return data.base64EncodedString()
		} catch {
			throw CLIError.invalidReferenceAudioPath(path, error)
		}
	}

	private func playAudio(at url: URL) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
		process.arguments = [url.path]
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

private func decodeJSONOrString(_ text: String) -> Any {
	guard let data = text.data(using: .utf8), !text.isEmpty else {
		return ""
	}
	if let value = try? JSONSerialization.jsonObject(with: data) {
		return value
	}
	return text
}

private func printJSONObject(_ object: [String: Any]) {
	guard JSONSerialization.isValidJSONObject(object),
		  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
		  let text = String(data: data, encoding: .utf8) else {
		print("{\"ok\":true}")
		return
	}
	print(text)
}
