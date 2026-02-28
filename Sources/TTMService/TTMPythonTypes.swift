import Foundation

public enum TTMPythonBridgeResources {
	public static var pythonModulesPath: String? {
		guard let resourceURL = Bundle.module.resourceURL else {
			return nil
		}
		return resourceURL.path
	}
}

public struct PythonRuntimeConfiguration: Sendable {
	public var pythonLibraryPath: String
	public var pythonHome: String
	public var moduleSearchPaths: [String]
	public var qwenModule: String

	public init(
		pythonLibraryPath: String,
		pythonHome: String,
		moduleSearchPaths: [String],
		qwenModule: String = "qwen_tts_runner"
	) {
		self.pythonLibraryPath = pythonLibraryPath
		self.pythonHome = pythonHome
		self.moduleSearchPaths = moduleSearchPaths
		self.qwenModule = qwenModule
	}
}

public struct QwenSynthesisRequest: Sendable {
	public var text: String
	public var mode: QwenSynthesisMode
	public var modelID: QwenModelIdentifier
	public var language: String
	public var voice: String
	public var instruct: String?
	public var referenceAudio: Data?
	public var sampleRate: Int

	public init(
		text: String,
		mode: QwenSynthesisMode,
		modelID: QwenModelIdentifier,
		language: String,
		voice: String,
		instruct: String? = nil,
		referenceAudio: Data? = nil,
		sampleRate: Int = 24_000
	) {
		self.text = text
		self.mode = mode
		self.modelID = modelID
		self.language = language
		self.voice = voice
		self.instruct = instruct
		self.referenceAudio = referenceAudio
		self.sampleRate = sampleRate
	}

	public static func voiceDesign(
		text: String,
		instruct: String,
		language: String,
		modelID: QwenModelIdentifier = .voiceDesign1_7B,
		sampleRate: Int = 24_000
	) -> Self {
		.init(
			text: text,
			mode: .voiceDesign,
			modelID: modelID,
			language: language,
			voice: instruct,
			instruct: nil,
			referenceAudio: nil,
			sampleRate: sampleRate
		)
	}

	public static func customVoice(
		text: String,
		speaker: String,
		instruct: String? = nil,
		language: String,
		modelID: QwenModelIdentifier = .customVoice0_6B,
		sampleRate: Int = 24_000
	) -> Self {
		.init(
			text: text,
			mode: .customVoice,
			modelID: modelID,
			language: language,
			voice: speaker,
			instruct: instruct,
			referenceAudio: nil,
			sampleRate: sampleRate
		)
	}

	public static func voiceClone(
		text: String,
		referenceAudio: Data,
		language: String,
		modelID: QwenModelIdentifier = .voiceClone0_6B,
		sampleRate: Int = 24_000
	) -> Self {
		.init(
			text: text,
			mode: .voiceClone,
			modelID: modelID,
			language: language,
			voice: "",
			instruct: nil,
			referenceAudio: referenceAudio,
			sampleRate: sampleRate
		)
	}
}

public enum QwenSynthesisMode: String, CaseIterable, Sendable {
	case voiceDesign = "voice_design"
	case customVoice = "custom_voice"
	case voiceClone = "voice_clone"
}

public enum QwenModelIdentifier: String, CaseIterable, Sendable {
	case voiceDesign1_7B = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
	case customVoice0_6B = "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
	case customVoice1_7B = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
	case voiceClone0_6B = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
	case voiceClone1_7B = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"

	public var mode: QwenSynthesisMode {
		switch self {
		case .voiceDesign1_7B:
			return .voiceDesign
		case .customVoice0_6B, .customVoice1_7B:
			return .customVoice
		case .voiceClone0_6B, .voiceClone1_7B:
			return .voiceClone
		}
	}

	public static func defaultModel(for mode: QwenSynthesisMode) -> Self {
		switch mode {
		case .voiceDesign:
			return .voiceDesign1_7B
		case .customVoice:
			return .customVoice0_6B
		case .voiceClone:
			return .voiceClone0_6B
		}
	}

	public static func fallbackOrder(for preferred: Self) -> [Self] {
		let sameMode = Self.allCases.filter { $0.mode == preferred.mode && $0 != preferred }
		let crossMode = Self.allCases.filter { $0.mode != preferred.mode }
		return [preferred] + sameMode + crossMode
	}
}

public struct QwenModelSelection: Sendable, Equatable {
	public var mode: QwenSynthesisMode
	public var modelID: QwenModelIdentifier

	public init(mode: QwenSynthesisMode, modelID: QwenModelIdentifier? = nil) {
		let resolvedModel = modelID ?? QwenModelIdentifier.defaultModel(for: mode)
		self.mode = mode
		self.modelID = resolvedModel
	}

	public static var defaultVoiceDesign: Self {
		.init(mode: .voiceDesign, modelID: .voiceDesign1_7B)
	}

	public static var defaultCustomVoice: Self {
		.init(mode: .customVoice, modelID: .customVoice0_6B)
	}

	public static var defaultVoiceClone: Self {
		.init(mode: .voiceClone, modelID: .voiceClone0_6B)
	}
}

public struct TTMPythonBridgeStatus: Sendable, Equatable {
	public var runtimeInitialized: Bool
	public var moduleLoaded: Bool
	public var modelLoaded: Bool
	public var activeMode: QwenSynthesisMode?
	public var activeModelID: QwenModelIdentifier?
	public var requestedMode: QwenSynthesisMode?
	public var requestedModelID: QwenModelIdentifier?
	public var strictLoad: Bool
	public var fallbackApplied: Bool
	public var ready: Bool
	public var lastError: String?

	public init(
		runtimeInitialized: Bool,
		moduleLoaded: Bool,
		modelLoaded: Bool,
		activeMode: QwenSynthesisMode?,
		activeModelID: QwenModelIdentifier?,
		requestedMode: QwenSynthesisMode?,
		requestedModelID: QwenModelIdentifier?,
		strictLoad: Bool,
		fallbackApplied: Bool,
		ready: Bool,
		lastError: String?
	) {
		self.runtimeInitialized = runtimeInitialized
		self.moduleLoaded = moduleLoaded
		self.modelLoaded = modelLoaded
		self.activeMode = activeMode
		self.activeModelID = activeModelID
		self.requestedMode = requestedMode
		self.requestedModelID = requestedModelID
		self.strictLoad = strictLoad
		self.fallbackApplied = fallbackApplied
		self.ready = ready
		self.lastError = lastError
	}
}

public enum TTMPythonBridgeError: Error, Sendable, Equatable {
	case alreadyInitialized
	case notInitialized
	case pythonLibraryLoadFailed(path: String)
	case missingSymbol(name: String)
	case pythonInitializeFailed
	case qwenModuleImportFailed(module: String)
	case qwenModuleNotLoaded
	case modelNotLoaded
	case pythonCallFailed(function: String)
	case invalidSynthesisReturnType
	case synthesisFailed(reason: String)
}

struct TTMQwenRuntimeEnvironment: Sendable, Equatable {
	let debugEnabled: Bool
	let deviceMap: String?
	let torchDtype: String?
	let allowFallback: Bool?
	let enableFinalize: Bool

	static func fromProcessInfo(_ processInfo: ProcessInfo = .processInfo) -> Self {
		fromEnvironment(processInfo.environment)
	}

	static func fromEnvironment(_ env: [String: String]) -> Self {
		let allowFallback = env["TTM_QWEN_ALLOW_FALLBACK"].flatMap { raw -> Bool? in
			switch raw.lowercased() {
			case "1", "true", "yes":
				return true
			case "0", "false", "no":
				return false
			default:
				return nil
			}
		}
		return .init(
			debugEnabled: env["TTM_QWEN_DEBUG"] == "1",
			deviceMap: env["TTM_QWEN_DEVICE_MAP"],
			torchDtype: env["TTM_QWEN_TORCH_DTYPE"],
			allowFallback: allowFallback,
			enableFinalize: env["TTM_PYTHON_ENABLE_FINALIZE"] == "1"
		)
	}
}
