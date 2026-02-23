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

	public init(configuration: TTMQwenServiceConfiguration, logger: Logger = .init(label: "TalkToMeKit.TTMQwenService")) {
		let bridge = TTMPythonBridge()
		self.bridge = bridge
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

	public func loadModel(selection: QwenModelSelection) async throws -> Bool {
		try await bridge.loadModel(selection: selection)
	}

	public func unloadModel() async throws -> Bool {
		try await bridge.unloadModel()
	}
}

private struct QwenPythonRuntimeService: Service {
	let bridge: TTMPythonBridge
	let configuration: PythonRuntimeConfiguration
	let startupSelection: QwenModelSelection

	func run() async throws {
		try await bridge.initialize(configuration: configuration)
		try await bridge.importQwenModule()
		let loaded = try await bridge.loadModel(selection: startupSelection)
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
