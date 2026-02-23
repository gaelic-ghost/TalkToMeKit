import Foundation
import Logging
import ServiceLifecycle
import TTMPythonRuntimeBundle

public enum TTMServiceRuntimeError: Error, Sendable, Equatable {
	case alreadyStarted
	case notStarted
	case notReady
	case invalidRequest
	case startupTimedOut(seconds: Int)
	case runtimeUnavailable
}

public enum TTMAssetPreparationState: Sendable, Equatable {
	case checking
	case downloading
	case validating
	case ready
}

public struct TTMServiceSynthesizeRequest: Sendable {
	public var text: String
	public var voice: String?
	public var instruct: String?
	public var referenceAudio: Data?
	public var mode: QwenSynthesisMode
	public var modelID: QwenModelIdentifier?
	public var language: String
	public var sampleRate: Int

	public init(
		text: String,
		voice: String? = nil,
		instruct: String? = nil,
		referenceAudio: Data? = nil,
		mode: QwenSynthesisMode = .customVoice,
		modelID: QwenModelIdentifier? = nil,
		language: String = "English",
		sampleRate: Int = 24_000
	) {
		self.text = text
		self.voice = voice
		self.instruct = instruct
		self.referenceAudio = referenceAudio
		self.mode = mode
		self.modelID = modelID
		self.language = language
		self.sampleRate = sampleRate
	}
}

public struct TTMServiceRuntimeStatus: Sendable, Equatable {
	public var started: Bool
	public var ready: Bool
	public var modelLoaded: Bool
	public var bridgeStatus: TTMPythonBridgeStatus?

	public init(started: Bool, ready: Bool, modelLoaded: Bool, bridgeStatus: TTMPythonBridgeStatus?) {
		self.started = started
		self.ready = ready
		self.modelLoaded = modelLoaded
		self.bridgeStatus = bridgeStatus
	}
}

public protocol TTMAssetProvider: Sendable {
	func resolveQwenServiceConfiguration() async throws -> TTMQwenServiceConfiguration
}

public struct TTMBundledRuntimeAssetProvider: TTMAssetProvider {
	public let pythonVersion: String

	public init(pythonVersion: String = "3.11") {
		self.pythonVersion = pythonVersion
	}

	public func resolveQwenServiceConfiguration() async throws -> TTMQwenServiceConfiguration {
		guard let configuration = TTMQwenServiceConfiguration.bundledCPythonIfAvailable(pythonVersion: pythonVersion) else {
			throw TTMServiceRuntimeError.runtimeUnavailable
		}
		return configuration
	}
}

public struct TTMLocalRuntimeAssetProvider: TTMAssetProvider {
	public let runtimeRoot: URL
	public let pythonVersion: String

	public init(runtimeRoot: URL, pythonVersion: String = "3.11") {
		self.runtimeRoot = runtimeRoot
		self.pythonVersion = pythonVersion
	}

	public func resolveQwenServiceConfiguration() async throws -> TTMQwenServiceConfiguration {
		guard let configuration = runtimeConfigurationIfValid(runtimeRoot: runtimeRoot, pythonVersion: pythonVersion) else {
			throw TTMServiceRuntimeError.runtimeUnavailable
		}
		return configuration
	}
}

public struct TTMFirstLaunchDownloadAssetProvider: TTMAssetProvider {
	public typealias DownloadHandler = @Sendable (URL, String) async throws -> Void
	public typealias StateChangeHandler = @Sendable (TTMAssetPreparationState) -> Void

	public let runtimeRoot: URL
	public let pythonVersion: String
	public let downloadIfNeeded: DownloadHandler
	public let onStateChange: StateChangeHandler

	public init(
		runtimeRoot: URL,
		pythonVersion: String = "3.11",
		downloadIfNeeded: @escaping DownloadHandler = { _, _ in },
		onStateChange: @escaping StateChangeHandler = { _ in }
	) {
		self.runtimeRoot = runtimeRoot
		self.pythonVersion = pythonVersion
		self.downloadIfNeeded = downloadIfNeeded
		self.onStateChange = onStateChange
	}

	public func resolveQwenServiceConfiguration() async throws -> TTMQwenServiceConfiguration {
		onStateChange(.checking)
		if let configuration = runtimeConfigurationIfValid(runtimeRoot: runtimeRoot, pythonVersion: pythonVersion) {
			onStateChange(.ready)
			return configuration
		}

		onStateChange(.downloading)
		try await downloadIfNeeded(runtimeRoot, pythonVersion)
		onStateChange(.validating)

		guard let configuration = runtimeConfigurationIfValid(runtimeRoot: runtimeRoot, pythonVersion: pythonVersion) else {
			throw TTMServiceRuntimeError.runtimeUnavailable
		}

		onStateChange(.ready)
		return configuration
	}
}

public struct TTMServiceRuntimeConfiguration: Sendable {
	public var assetProvider: any TTMAssetProvider
	public var startupTimeoutSeconds: Int
	public var logger: Logger

	public init(
		assetProvider: any TTMAssetProvider = TTMBundledRuntimeAssetProvider(),
		startupTimeoutSeconds: Int = 60,
		logger: Logger = .init(label: "TalkToMeKit.TTMServiceRuntime")
	) {
		self.assetProvider = assetProvider
		self.startupTimeoutSeconds = startupTimeoutSeconds
		self.logger = logger
	}
}

public extension TTMServiceRuntimeConfiguration {
	static func bundled(
		pythonVersion: String = "3.11",
		startupTimeoutSeconds: Int = 60,
		logger: Logger = .init(label: "TalkToMeKit.TTMServiceRuntime")
	) -> Self {
		.init(
			assetProvider: TTMBundledRuntimeAssetProvider(pythonVersion: pythonVersion),
			startupTimeoutSeconds: startupTimeoutSeconds,
			logger: logger
		)
	}

	static func local(
		runtimeRoot: URL,
		pythonVersion: String = "3.11",
		startupTimeoutSeconds: Int = 60,
		logger: Logger = .init(label: "TalkToMeKit.TTMServiceRuntime")
	) -> Self {
		.init(
			assetProvider: TTMLocalRuntimeAssetProvider(runtimeRoot: runtimeRoot, pythonVersion: pythonVersion),
			startupTimeoutSeconds: startupTimeoutSeconds,
			logger: logger
		)
	}

	static func firstLaunch(
		runtimeRoot: URL,
		pythonVersion: String = "3.11",
		startupTimeoutSeconds: Int = 60,
		logger: Logger = .init(label: "TalkToMeKit.TTMServiceRuntime"),
		downloadIfNeeded: @escaping TTMFirstLaunchDownloadAssetProvider.DownloadHandler,
		onStateChange: @escaping TTMFirstLaunchDownloadAssetProvider.StateChangeHandler = { _ in }
	) -> Self {
		.init(
			assetProvider: TTMFirstLaunchDownloadAssetProvider(
				runtimeRoot: runtimeRoot,
				pythonVersion: pythonVersion,
				downloadIfNeeded: downloadIfNeeded,
				onStateChange: onStateChange
			),
			startupTimeoutSeconds: startupTimeoutSeconds,
			logger: logger
		)
	}
}

public actor TTMServiceRuntime {
	private let configuration: TTMServiceRuntimeConfiguration
	private var qwenService: TTMQwenService?
	private var runTask: Task<Void, Error>?

	public init(configuration: TTMServiceRuntimeConfiguration = .init()) {
		self.configuration = configuration
	}

	public func start() async throws {
		guard runTask == nil else {
			throw TTMServiceRuntimeError.alreadyStarted
		}

		let qwenConfiguration = try await configuration.assetProvider.resolveQwenServiceConfiguration()
		let service = TTMQwenService(configuration: qwenConfiguration, logger: configuration.logger)
		qwenService = service
		runTask = Task {
			try await service.run()
		}

		do {
			try await waitForReady(service: service, timeoutSeconds: configuration.startupTimeoutSeconds)
		} catch {
			let task = runTask
			runTask = nil
			qwenService = nil
			task?.cancel()
			_ = await task?.result
			throw error
		}
	}

	public func stop() async {
		let task = runTask
		runTask = nil
		qwenService = nil
		task?.cancel()
		_ = await task?.result
	}

	public func status() async -> TTMServiceRuntimeStatus {
		guard let service = qwenService else {
			return .init(started: false, ready: false, modelLoaded: false, bridgeStatus: nil)
		}
		let bridgeStatus = await service.status()
		return .init(
			started: runTask != nil,
			ready: bridgeStatus.ready,
			modelLoaded: bridgeStatus.modelLoaded,
			bridgeStatus: bridgeStatus
		)
	}

	public func synthesize(_ request: TTMServiceSynthesizeRequest) async throws -> Data {
		guard let service = qwenService else {
			throw TTMServiceRuntimeError.notStarted
		}
		guard await service.isReady() else {
			throw TTMServiceRuntimeError.notReady
		}

		let resolvedModelID = request.modelID ?? QwenModelIdentifier.defaultModel(for: request.mode)
		let qwenRequest: QwenSynthesisRequest
		switch request.mode {
		case .voiceDesign:
			qwenRequest = .voiceDesign(
				text: request.text,
				instruct: request.instruct ?? request.voice ?? "",
				language: request.language,
				modelID: resolvedModelID,
				sampleRate: request.sampleRate
			)
		case .customVoice:
			qwenRequest = .customVoice(
				text: request.text,
				speaker: request.voice ?? "ryan",
				instruct: request.instruct,
				language: request.language,
				modelID: resolvedModelID,
				sampleRate: request.sampleRate
			)
		case .voiceClone:
			guard let referenceAudio = request.referenceAudio else {
				throw TTMServiceRuntimeError.invalidRequest
			}
			qwenRequest = .voiceClone(
				text: request.text,
				referenceAudio: referenceAudio,
				language: request.language,
				modelID: resolvedModelID,
				sampleRate: request.sampleRate
			)
		}

		return try await service.synthesize(qwenRequest)
	}

	private func waitForReady(service: TTMQwenService, timeoutSeconds: Int) async throws {
		let timeout = max(1, timeoutSeconds)
		let deadline = Date().addingTimeInterval(TimeInterval(timeout))

		while Date() < deadline {
			if await service.isReady() {
				return
			}
			try await Task.sleep(for: .milliseconds(200))
		}

		throw TTMServiceRuntimeError.startupTimedOut(seconds: timeout)
	}
}

private func runtimeConfigurationIfValid(runtimeRoot: URL, pythonVersion: String) -> TTMQwenServiceConfiguration? {
	let fileManager = FileManager.default
	let libPath = runtimeRoot
		.appendingPathComponent("lib")
		.appendingPathComponent("libpython\(pythonVersion).dylib")
		.path
	let stdlibPath = runtimeRoot
		.appendingPathComponent("lib")
		.appendingPathComponent("python\(pythonVersion)")
		.path

	guard fileManager.fileExists(atPath: libPath) else {
		return nil
	}
	guard fileManager.fileExists(atPath: stdlibPath) else {
		return nil
	}

	return TTMQwenServiceConfiguration.bundledCPython(runtimeRoot: runtimeRoot, pythonVersion: pythonVersion)
}


public struct TTMModelInventoryItem: Sendable, Equatable {
	public var mode: QwenSynthesisMode
	public var modelID: QwenModelIdentifier
	public var available: Bool
	public var localPath: String

	public init(mode: QwenSynthesisMode, modelID: QwenModelIdentifier, available: Bool, localPath: String) {
		self.mode = mode
		self.modelID = modelID
		self.available = available
		self.localPath = localPath
	}
}

public struct TTMQwenServiceConfiguration: Sendable {
	public var runtime: PythonRuntimeConfiguration
	public var startupSelection: QwenModelSelection

	public init(
		runtime: PythonRuntimeConfiguration,
		startupSelection: QwenModelSelection = .defaultVoiceDesign
	) {
		self.runtime = runtime
		self.startupSelection = startupSelection
	}

	public static func bundledCPython(
		runtimeRoot: URL,
		pythonVersion: String = "3.11",
		qwenModule: String = "qwen_tts_runner",
		additionalModuleSearchPaths: [String] = [],
		startupSelection: QwenModelSelection = .defaultVoiceDesign
	) -> Self {
		let libPath = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("libpython\(pythonVersion).dylib")
			.path
		let pythonStdlibPath = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("python\(pythonVersion)")
			.path
		let sitePackagesPath = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("python\(pythonVersion)")
			.appendingPathComponent("site-packages")
			.path
		let bundledModulePaths = [TTMPythonBridgeResources.pythonModulesPath].compactMap { $0 }
		let moduleSearchPaths = [pythonStdlibPath, sitePackagesPath] + bundledModulePaths + additionalModuleSearchPaths

		return .init(
			runtime: .init(
				pythonLibraryPath: libPath,
				pythonHome: runtimeRoot.path,
				moduleSearchPaths: moduleSearchPaths,
				qwenModule: qwenModule
			),
			startupSelection: startupSelection
		)
	}

	public static func bundledCPythonIfAvailable(
		pythonVersion: String = "3.11",
		qwenModule: String = "qwen_tts_runner",
		additionalModuleSearchPaths: [String] = [],
		startupSelection: QwenModelSelection = .defaultVoiceDesign
	) -> Self? {
		guard let bundledRuntime = TTMPythonRuntimeBundleLocator.bundledRuntime(pythonVersion: pythonVersion) else {
			return nil
		}

		let bundledModulePaths = [TTMPythonBridgeResources.pythonModulesPath].compactMap { $0 }
		let moduleSearchPaths = bundledRuntime.moduleSearchPaths.map(\.path) + bundledModulePaths + additionalModuleSearchPaths
		return .init(
			runtime: .init(
				pythonLibraryPath: bundledRuntime.libraryURL.path,
				pythonHome: bundledRuntime.rootURL.path,
				moduleSearchPaths: moduleSearchPaths,
				qwenModule: qwenModule
			),
			startupSelection: startupSelection
		)
	}
}

public struct TTMQwenService: Service {
	private let bridge: TTMPythonBridge
	private let group: ServiceGroup
	private let runtimeRoot: URL

	public init(configuration: TTMQwenServiceConfiguration, logger: Logger = .init(label: "TalkToMeKit.TTMQwenService")) {
		let bridge = TTMPythonBridge()
		self.bridge = bridge
		runtimeRoot = URL(fileURLWithPath: configuration.runtime.pythonHome, isDirectory: true)
		let runtimeService = QwenPythonRuntimeService(
			bridge: bridge,
			configuration: configuration.runtime,
			startupSelection: configuration.startupSelection
		)
		let inferenceService = QwenInferenceService(bridge: bridge)

		group = ServiceGroup(
			services: [runtimeService, inferenceService],
			logger: logger
		)
	}

	public func run() async throws {
		try await group.run()
	}

	public func synthesize(_ request: QwenSynthesisRequest) async throws -> Data {
		try await bridge.synthesize(request)
	}

	public func isReady() async -> Bool {
		await bridge.isReady
	}

	public func isModelLoaded() async -> Bool {
		await bridge.isModelLoaded()
	}

	public func status() async -> TTMPythonBridgeStatus {
		await bridge.status()
	}

	public func loadModel(selection: QwenModelSelection, strict: Bool = false) async throws -> Bool {
		try await bridge.loadModel(selection: selection, strict: strict)
	}

	public func unloadModel() async throws -> Bool {
		try await bridge.unloadModel()
	}

	public func supportedCustomVoiceSpeakers(modelID: QwenModelIdentifier) async throws -> [String] {
		try await bridge.supportedSpeakers(selection: .init(mode: .customVoice, modelID: modelID))
	}

	public func modelInventory() async -> [TTMModelInventoryItem] {
		let root = runtimeRoot
		let fileManager = FileManager.default
		return QwenModelIdentifier.allCases.map { modelID in
			let localPath = root
				.appendingPathComponent("models")
				.appendingPathComponent(modelID.rawValue.split(separator: "/").last.map(String.init) ?? "")
				.path
			return .init(
				mode: modelID.mode,
				modelID: modelID,
				available: fileManager.fileExists(atPath: localPath),
				localPath: localPath
			)
		}
	}
}

private struct QwenPythonRuntimeService: Service {
	let bridge: TTMPythonBridge
	let configuration: PythonRuntimeConfiguration
	let startupSelection: QwenModelSelection

	func run() async throws {
		try await bridge.initialize(configuration: configuration)
		try await bridge.importQwenModule()
		let loaded = try await bridge.loadModel(selection: startupSelection, strict: false)
		guard loaded else {
			throw TTMPythonBridgeError.pythonCallFailed(function: "load_model")
		}

		do {
			while !Task.isCancelled {
				try await Task.sleep(for: .seconds(60))
			}
		} catch is CancellationError {
			// Normal shutdown path.
		}

		await bridge.shutdown()
	}
}

private struct QwenInferenceService: Service {
	let bridge: TTMPythonBridge

	func run() async throws {
		do {
			while !Task.isCancelled {
				_ = bridge
				try await Task.sleep(for: .seconds(60))
			}
		} catch is CancellationError {
			// Normal shutdown path.
		}
	}
}
