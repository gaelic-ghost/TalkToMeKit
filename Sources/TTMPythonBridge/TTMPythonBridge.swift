import Darwin
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
	public var sampleRate: Int

	public init(
		text: String,
		mode: QwenSynthesisMode,
		modelID: QwenModelIdentifier,
		language: String,
		voice: String,
		instruct: String? = nil,
		sampleRate: Int = 24_000
	) {
		self.text = text
		self.mode = mode
		self.modelID = modelID
		self.language = language
		self.voice = voice
		self.instruct = instruct
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
				sampleRate: sampleRate
			)
		}
}

public enum QwenSynthesisMode: String, CaseIterable, Sendable {
	case voiceDesign = "voice_design"
	case customVoice = "custom_voice"
}

public enum QwenModelIdentifier: String, CaseIterable, Sendable {
	case voiceDesign1_7B = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
	case customVoice0_6B = "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
	case customVoice1_7B = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"

	public var mode: QwenSynthesisMode {
		switch self {
		case .voiceDesign1_7B:
			return .voiceDesign
		case .customVoice0_6B, .customVoice1_7B:
			return .customVoice
		}
	}

	public static func defaultModel(for mode: QwenSynthesisMode) -> Self {
		switch mode {
		case .voiceDesign:
			return .voiceDesign1_7B
		case .customVoice:
			return .customVoice0_6B
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

public actor TTMPythonBridge {
	private var runtime: CPythonRuntime?
	private var configuration: PythonRuntimeConfiguration?
	private var qwenModuleLoaded = false
	private var modelLoaded = false
	private var activeSelection: QwenModelSelection?
	private var requestedSelection: QwenModelSelection?
	private var lastStrictLoad = false
	private var lastFallbackApplied = false
	private var lastError: String?
	private let pythonExecutionQueue = DispatchQueue(label: "TalkToMeKit.TTMPythonBridge.CPython")

	public init() {}

	public var isReady: Bool {
		runtime != nil && qwenModuleLoaded && modelLoaded
	}

	public func status() -> TTMPythonBridgeStatus {
		.init(
			runtimeInitialized: runtime != nil,
			moduleLoaded: qwenModuleLoaded,
			modelLoaded: modelLoaded,
			activeMode: activeSelection?.mode,
			activeModelID: activeSelection?.modelID,
			requestedMode: requestedSelection?.mode,
			requestedModelID: requestedSelection?.modelID,
			strictLoad: lastStrictLoad,
			fallbackApplied: lastFallbackApplied,
			ready: isReady,
			lastError: lastError
		)
	}

	public func initialize(configuration: PythonRuntimeConfiguration) throws {
		guard runtime == nil else {
			throw TTMPythonBridgeError.alreadyInitialized
		}

		do {
			let runtime = try CPythonRuntime(libraryPath: configuration.pythonLibraryPath)
			try runtime.configureEnvironment(configuration)
			try runtime.initialize()

			self.runtime = runtime
			self.configuration = configuration
			qwenModuleLoaded = false
			modelLoaded = false
			activeSelection = nil
			requestedSelection = nil
			lastStrictLoad = false
			lastFallbackApplied = false
			lastError = nil
		} catch {
			lastError = String(describing: error)
			throw error
		}
	}

	public func importQwenModule() async throws {
		guard let runtime, let configuration else {
			throw TTMPythonBridgeError.notInitialized
		}

		do {
			try await blockingCall {
				try runtime.importModule(named: configuration.qwenModule)
			}
			qwenModuleLoaded = true
			modelLoaded = false
			lastError = nil
		} catch {
			lastError = String(describing: error)
			throw error
		}
	}

	public func synthesize(_ request: QwenSynthesisRequest) async throws -> Data {
		guard let runtime, let configuration else {
			throw TTMPythonBridgeError.notInitialized
		}
		guard qwenModuleLoaded else {
			throw TTMPythonBridgeError.qwenModuleNotLoaded
		}
		let requestedSelection = QwenModelSelection(mode: request.mode, modelID: request.modelID)
		if activeSelection != requestedSelection || !modelLoaded {
			let loaded = try await loadModel(selection: requestedSelection, strict: false)
			guard loaded else {
				throw TTMPythonBridgeError.modelNotLoaded
			}
		}

		do {
			let output = try await blockingCall {
				try runtime.synthesize(moduleName: configuration.qwenModule, request: request)
			}
			lastError = nil
			return output
		} catch {
			lastError = String(describing: error)
			throw error
		}
	}

	public func isModelLoaded() -> Bool {
		modelLoaded
	}

	public func loadModel(selection: QwenModelSelection, strict: Bool = false) async throws -> Bool {
		guard let runtime, let configuration else {
			throw TTMPythonBridgeError.notInitialized
		}
		guard qwenModuleLoaded else {
			throw TTMPythonBridgeError.qwenModuleNotLoaded
		}
		requestedSelection = selection
		lastStrictLoad = strict
		lastFallbackApplied = false
		let orderedSelections: [QwenModelSelection]
		if strict {
			orderedSelections = [selection]
		} else {
			orderedSelections = QwenModelIdentifier
				.fallbackOrder(for: selection.modelID)
				.map { QwenModelSelection(mode: $0.mode, modelID: $0) }
		}

		for candidate in orderedSelections {
			guard candidate.modelID.mode == candidate.mode else {
				continue
			}
			do {
				let loaded = try await blockingCall {
					try runtime.callBooleanFunction(
						moduleName: configuration.qwenModule,
						functionName: "load_model",
						stringArguments: [candidate.mode.rawValue, candidate.modelID.rawValue, strict ? "1" : "0"]
					)
				}
				if loaded {
					modelLoaded = true
					activeSelection = candidate
					lastFallbackApplied = candidate != selection
					lastError = nil
					return true
				}
				lastError = "load_model returned false for \(candidate.modelID.rawValue)"
			} catch {
				lastError = String(describing: error)
			}
		}
		modelLoaded = false
		activeSelection = nil
		lastFallbackApplied = false
		return false
	}

	public func supportedSpeakers(selection: QwenModelSelection) async throws -> [String] {
		guard selection.mode == .customVoice else {
			return []
		}
		guard let runtime, let configuration else {
			throw TTMPythonBridgeError.notInitialized
		}
		guard qwenModuleLoaded else {
			throw TTMPythonBridgeError.qwenModuleNotLoaded
		}

		_ = try await loadModel(selection: selection, strict: true)
		let csv = try await blockingCall {
			try runtime.callStringFunction(
				moduleName: configuration.qwenModule,
				functionName: "get_supported_speakers_csv",
				stringArguments: [selection.mode.rawValue, selection.modelID.rawValue]
			)
		}
		let speakers = csv
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		return speakers
	}

	public func runtimeRootPath() -> String? {
		configuration?.pythonHome
	}

	public func unloadModel() async throws -> Bool {
		guard let runtime, let configuration else {
			throw TTMPythonBridgeError.notInitialized
		}
		guard qwenModuleLoaded else {
			throw TTMPythonBridgeError.qwenModuleNotLoaded
		}
		do {
			let unloaded = try await blockingCall {
				try runtime.callBooleanFunction(
					moduleName: configuration.qwenModule,
					functionName: "unload_model"
				)
			}
			modelLoaded = !unloaded
			activeSelection = unloaded ? nil : activeSelection
			lastError = nil
			return unloaded
		} catch {
			lastError = String(describing: error)
			throw error
		}
	}

	public func shutdown() {
		runtime?.shutdown()
		runtime = nil
		configuration = nil
		qwenModuleLoaded = false
		modelLoaded = false
		activeSelection = nil
		requestedSelection = nil
		lastStrictLoad = false
		lastFallbackApplied = false
		lastError = nil
	}

	private func blockingCall<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			pythonExecutionQueue.async {
				do {
					continuation.resume(returning: try operation())
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}

private final class CPythonRuntime: @unchecked Sendable {
	private typealias PyObject = OpaquePointer
	private typealias PyGILStateState = Int32
	private typealias PyThreadState = UnsafeMutableRawPointer

	private typealias PyInitializeExFn = @convention(c) (Int32) -> Void
	private typealias PyFinalizeExFn = @convention(c) () -> Int32
	private typealias PyIsInitializedFn = @convention(c) () -> Int32
	private typealias PyImportImportModuleFn = @convention(c) (UnsafePointer<CChar>) -> PyObject?
	private typealias PyObjectGetAttrStringFn = @convention(c) (PyObject?, UnsafePointer<CChar>) -> PyObject?
	private typealias PyCallableCheckFn = @convention(c) (PyObject?) -> Int32
	private typealias PyTupleNewFn = @convention(c) (Int) -> PyObject?
	private typealias PyTupleSetItemFn = @convention(c) (PyObject?, Int, PyObject?) -> Int32
	private typealias PyUnicodeFromStringFn = @convention(c) (UnsafePointer<CChar>) -> PyObject?
	private typealias PyLongFromLongFn = @convention(c) (Int) -> PyObject?
	private typealias PyObjectCallObjectFn = @convention(c) (PyObject?, PyObject?) -> PyObject?
	private typealias PyObjectIsTrueFn = @convention(c) (PyObject?) -> Int32
	private typealias PyBytesAsStringAndSizeFn = @convention(c) (PyObject?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?) -> Int32
	private typealias PyUnicodeAsUTF8Fn = @convention(c) (PyObject?) -> UnsafePointer<CChar>?
	private typealias PyDecRefFn = @convention(c) (PyObject?) -> Void
	private typealias PyErrPrintExFn = @convention(c) (Int32) -> Void
	private typealias PyGILStateEnsureFn = @convention(c) () -> PyGILStateState
	private typealias PyGILStateReleaseFn = @convention(c) (PyGILStateState) -> Void
	private typealias PyEvalSaveThreadFn = @convention(c) () -> PyThreadState?
	private typealias PyEvalRestoreThreadFn = @convention(c) (PyThreadState?) -> Void

	private let handle: UnsafeMutableRawPointer
	private let pyInitializeEx: PyInitializeExFn
	private let pyFinalizeEx: PyFinalizeExFn
	private let pyIsInitialized: PyIsInitializedFn
	private let pyImportImportModule: PyImportImportModuleFn
	private let pyObjectGetAttrString: PyObjectGetAttrStringFn
	private let pyCallableCheck: PyCallableCheckFn
	private let pyTupleNew: PyTupleNewFn
	private let pyTupleSetItem: PyTupleSetItemFn
	private let pyUnicodeFromString: PyUnicodeFromStringFn
	private let pyLongFromLong: PyLongFromLongFn
	private let pyObjectCallObject: PyObjectCallObjectFn
	private let pyObjectIsTrue: PyObjectIsTrueFn
	private let pyBytesAsStringAndSize: PyBytesAsStringAndSizeFn
	private let pyUnicodeAsUTF8: PyUnicodeAsUTF8Fn
	private let pyDecRef: PyDecRefFn
	private let pyErrPrintEx: PyErrPrintExFn
	private let pyGILStateEnsure: PyGILStateEnsureFn
	private let pyGILStateRelease: PyGILStateReleaseFn
	private let pyEvalSaveThread: PyEvalSaveThreadFn
	private let pyEvalRestoreThread: PyEvalRestoreThreadFn
	private var releasedThreadState: PyThreadState?

	init(libraryPath: String) throws {
		guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_GLOBAL) else {
			throw TTMPythonBridgeError.pythonLibraryLoadFailed(path: libraryPath)
		}
		self.handle = handle

		pyInitializeEx = try Self.loadSymbol(handle: handle, "Py_InitializeEx", as: PyInitializeExFn.self)
		pyFinalizeEx = try Self.loadSymbol(handle: handle, "Py_FinalizeEx", as: PyFinalizeExFn.self)
		pyIsInitialized = try Self.loadSymbol(handle: handle, "Py_IsInitialized", as: PyIsInitializedFn.self)
		pyImportImportModule = try Self.loadSymbol(handle: handle, "PyImport_ImportModule", as: PyImportImportModuleFn.self)
		pyObjectGetAttrString = try Self.loadSymbol(handle: handle, "PyObject_GetAttrString", as: PyObjectGetAttrStringFn.self)
		pyCallableCheck = try Self.loadSymbol(handle: handle, "PyCallable_Check", as: PyCallableCheckFn.self)
		pyTupleNew = try Self.loadSymbol(handle: handle, "PyTuple_New", as: PyTupleNewFn.self)
		pyTupleSetItem = try Self.loadSymbol(handle: handle, "PyTuple_SetItem", as: PyTupleSetItemFn.self)
		pyUnicodeFromString = try Self.loadSymbol(handle: handle, "PyUnicode_FromString", as: PyUnicodeFromStringFn.self)
		pyLongFromLong = try Self.loadSymbol(handle: handle, "PyLong_FromLong", as: PyLongFromLongFn.self)
		pyObjectCallObject = try Self.loadSymbol(handle: handle, "PyObject_CallObject", as: PyObjectCallObjectFn.self)
		pyObjectIsTrue = try Self.loadSymbol(handle: handle, "PyObject_IsTrue", as: PyObjectIsTrueFn.self)
		pyBytesAsStringAndSize = try Self.loadSymbol(handle: handle, "PyBytes_AsStringAndSize", as: PyBytesAsStringAndSizeFn.self)
		pyUnicodeAsUTF8 = try Self.loadSymbol(handle: handle, "PyUnicode_AsUTF8", as: PyUnicodeAsUTF8Fn.self)
		pyDecRef = try Self.loadSymbol(handle: handle, "Py_DecRef", as: PyDecRefFn.self)
		pyErrPrintEx = try Self.loadSymbol(handle: handle, "PyErr_PrintEx", as: PyErrPrintExFn.self)
		pyGILStateEnsure = try Self.loadSymbol(handle: handle, "PyGILState_Ensure", as: PyGILStateEnsureFn.self)
		pyGILStateRelease = try Self.loadSymbol(handle: handle, "PyGILState_Release", as: PyGILStateReleaseFn.self)
		pyEvalSaveThread = try Self.loadSymbol(handle: handle, "PyEval_SaveThread", as: PyEvalSaveThreadFn.self)
		pyEvalRestoreThread = try Self.loadSymbol(handle: handle, "PyEval_RestoreThread", as: PyEvalRestoreThreadFn.self)
		releasedThreadState = nil
	}

	func configureEnvironment(_ configuration: PythonRuntimeConfiguration) throws {
		guard setenv("PYTHONHOME", configuration.pythonHome, 1) == 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
		let pythonPath = configuration.moduleSearchPaths.joined(separator: ":")
		guard setenv("PYTHONPATH", pythonPath, 1) == 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
	}

	func initialize() throws {
		// When finalization is disabled (default), CPython may already be process-initialized
		// by a prior bridge instance. Re-running PyEval_SaveThread in that state can crash.
		guard pyIsInitialized() == 0 else {
			releasedThreadState = nil
			return
		}
		pyInitializeEx(0)
		guard pyIsInitialized() != 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
		// Release the GIL after initialization so future calls from other threads can acquire it.
		releasedThreadState = pyEvalSaveThread()
	}

	func importModule(named name: String) throws {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = name.withCString { pyImportImportModule($0) }
		guard module != nil else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: name)
		}
	}

	func synthesize(moduleName: String, request: QwenSynthesisRequest) throws -> Data {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let functionName: String
		switch request.mode {
		case .voiceDesign:
			functionName = "synthesize_voice_design"
		case .customVoice:
			functionName = "synthesize_custom_voice"
		}
		let synthFn = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let synthFn else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(synthFn) }

		guard pyCallableCheck(synthFn) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

			let argumentCount = request.mode == .customVoice ? 6 : 5
			guard let args = pyTupleNew(argumentCount) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			defer { pyDecRef(args) }

		guard let textObject = request.text.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let voiceObject = request.voice.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let languageObject = request.language.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let sampleRateObject = pyLongFromLong(request.sampleRate) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
			guard let modelObject = request.modelID.rawValue.withCString({ pyUnicodeFromString($0) }) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			let instructValue = request.instruct ?? ""
			var instructObject: PyObject?
			if request.mode == .customVoice {
				guard let created = instructValue.withCString({ pyUnicodeFromString($0) }) else {
					pyErrPrintEx(0)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
				instructObject = created
			}

		// PyTuple_SetItem steals references on success.
		guard pyTupleSetItem(args, 0, textObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(textObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard pyTupleSetItem(args, 1, voiceObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(voiceObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
			let languageIndex = request.mode == .customVoice ? 3 : 2
			guard pyTupleSetItem(args, languageIndex, languageObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(languageObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			let sampleRateIndex = request.mode == .customVoice ? 4 : 3
			guard pyTupleSetItem(args, sampleRateIndex, sampleRateObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(sampleRateObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			let modelIndex = request.mode == .customVoice ? 5 : 4
			guard pyTupleSetItem(args, modelIndex, modelObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(modelObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			if request.mode == .customVoice, let instructObject {
				guard pyTupleSetItem(args, 2, instructObject) == 0 else {
					pyErrPrintEx(0)
					pyDecRef(instructObject)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
			}

		guard let result = pyObjectCallObject(synthFn, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		var buffer: UnsafeMutablePointer<CChar>?
		var byteCount = 0
		guard pyBytesAsStringAndSize(result, &buffer, &byteCount) == 0 else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.invalidSynthesisReturnType
		}
		guard let buffer else {
			throw TTMPythonBridgeError.invalidSynthesisReturnType
		}

		return Data(bytes: buffer, count: byteCount)
	}

	func callBooleanFunction(moduleName: String, functionName: String, stringArguments: [String] = []) throws -> Bool {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let function = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let function else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(function) }

		guard pyCallableCheck(function) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

		var args: PyObject?
		if !stringArguments.isEmpty {
			guard let tuple = pyTupleNew(stringArguments.count) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			for (index, argument) in stringArguments.enumerated() {
				guard let argObject = argument.withCString({ pyUnicodeFromString($0) }) else {
					pyErrPrintEx(0)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
				guard pyTupleSetItem(tuple, index, argObject) == 0 else {
					pyErrPrintEx(0)
					pyDecRef(argObject)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
			}
			args = tuple
		}
		defer {
			if let args {
				pyDecRef(args)
			}
		}

		guard let result = pyObjectCallObject(function, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		let truthy = pyObjectIsTrue(result)
		guard truthy != -1 else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		return truthy != 0
	}

	func callStringFunction(moduleName: String, functionName: String, stringArguments: [String] = []) throws -> String {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let function = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let function else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(function) }

		guard pyCallableCheck(function) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

		var args: PyObject?
		if !stringArguments.isEmpty {
			guard let tuple = pyTupleNew(stringArguments.count) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			for (index, argument) in stringArguments.enumerated() {
				guard let argObject = argument.withCString({ pyUnicodeFromString($0) }) else {
					pyErrPrintEx(0)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
				guard pyTupleSetItem(tuple, index, argObject) == 0 else {
					pyErrPrintEx(0)
					pyDecRef(argObject)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
			}
			args = tuple
		}
		defer {
			if let args {
				pyDecRef(args)
			}
		}

		guard let result = pyObjectCallObject(function, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		guard let utf8 = pyUnicodeAsUTF8(result) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		return String(cString: utf8)
	}

	func shutdown() {
		// CPython finalization is unsafe for long-lived native extensions (e.g. torch background threads).
		// Keep finalize/dlclose opt-in to avoid process crashes during shutdown/tests.
		let shouldFinalize = ProcessInfo.processInfo.environment["TTM_PYTHON_ENABLE_FINALIZE"] == "1"
		guard shouldFinalize else {
			return
		}
		if pyIsInitialized() != 0 {
			if releasedThreadState != nil {
				pyEvalRestoreThread(releasedThreadState)
				releasedThreadState = nil
			}
			_ = pyFinalizeEx()
		}
		dlclose(handle)
	}

	private static func loadSymbol<T>(handle: UnsafeMutableRawPointer, _ symbol: String, as type: T.Type) throws -> T {
		guard let ptr = dlsym(handle, symbol) else {
			throw TTMPythonBridgeError.missingSymbol(name: symbol)
		}
		return unsafeBitCast(ptr, to: T.self)
	}
}
