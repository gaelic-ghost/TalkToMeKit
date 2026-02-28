import Darwin
import Foundation

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
	private let runtimeEnvironment: TTMQwenRuntimeEnvironment

	public init() {
		self.runtimeEnvironment = .fromProcessInfo()
	}

	init(runtimeEnvironment: TTMQwenRuntimeEnvironment) {
		self.runtimeEnvironment = runtimeEnvironment
	}

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
			debugLog("initialize: pythonLibraryPath=\(configuration.pythonLibraryPath) pythonHome=\(configuration.pythonHome) moduleSearchPaths=\(configuration.moduleSearchPaths.joined(separator: ":"))")
			debugLog("initialize: env PYTHONHOME=\(environmentValue("PYTHONHOME"))")
			debugLog("initialize: env PYTHONPATH=\(environmentValue("PYTHONPATH"))")
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
			await logRunnerDiagnosticsIfAvailable(runtime: runtime, configuration: configuration, context: "importQwenModule")
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
		debugLog("loadModel: requested mode=\(selection.mode.rawValue) model=\(selection.modelID.rawValue) strict=\(strict) device_map=\(runtimeEnvironment.deviceMap ?? "<unset>") dtype=\(runtimeEnvironment.torchDtype ?? "<unset>")")
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
				await logRunnerDiagnosticsIfAvailable(runtime: runtime, configuration: configuration, context: "loadModel:\(candidate.modelID.rawValue)")
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
		runtime?.shutdown(shouldFinalize: runtimeEnvironment.enableFinalize)
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

	private func environmentValue(_ key: String) -> String {
		guard let value = getenv(key) else {
			return "<unset>"
		}
		return String(cString: value)
	}

	private func debugLog(_ message: String) {
		guard runtimeEnvironment.debugEnabled else { return }
		fputs("[TTMPythonBridge] \(message)\n", stderr)
	}

	private func logRunnerDiagnosticsIfAvailable(
		runtime: CPythonRuntime,
		configuration: PythonRuntimeConfiguration,
		context: String
	) async {
		guard runtimeEnvironment.debugEnabled else { return }
		do {
			let diagnostics = try await blockingCall {
				try runtime.callStringFunction(
					moduleName: configuration.qwenModule,
					functionName: "get_runtime_diagnostics"
				)
			}
			debugLog("\(context): runner_diagnostics=\(diagnostics)")
		} catch {
			debugLog("\(context): runner_diagnostics_unavailable error=\(error)")
		}
	}
}
