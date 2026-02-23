//
//  TTMQwenService.swift
//  TalkToMeKit
//
//  Created by Gale Williams on 2/22/26.
//

import Foundation
import Logging
import ServiceLifecycle
import TTMPythonBridge
import TTMPythonRuntimeBundle

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
