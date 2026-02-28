import ArgumentParser
import Foundation

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
		try SynthesisRequestBuilder.validateInput(text: text, textFile: textFile, mode: mode, referenceAudio: referenceAudio)
	}

	mutating func run() async throws {
		let builtRequest = try SynthesisRequestBuilder.buildRequest(
			from: .init(
				text: text,
				textFile: textFile,
				mode: mode,
				speaker: speaker,
				instruct: instruct,
				language: language,
				modelID: modelID,
				referenceAudio: referenceAudio,
				format: format
			)
		)

		let result = try await global.makeClient().synthesize(path: builtRequest.path, payload: builtRequest.payload)
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
		try SynthesisRequestBuilder.validateInput(text: text, textFile: textFile, mode: mode, referenceAudio: referenceAudio)
	}

	mutating func run() async throws {
		let builtRequest = try SynthesisRequestBuilder.buildRequest(
			from: .init(
				text: text,
				textFile: textFile,
				mode: mode,
				speaker: speaker,
				instruct: instruct,
				language: language,
				modelID: modelID,
				referenceAudio: referenceAudio,
				format: format
			)
		)

		let result = try await global.makeClient().synthesize(path: builtRequest.path, payload: builtRequest.payload)
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
		try AfplayAudioPlayer().play(audioURL: tempURL)
	}
}
