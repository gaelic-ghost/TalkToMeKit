import ArgumentParser
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import ServiceLifecycle
import TTMService
import TTMPythonBridge

@main
struct TTMServerMain: AsyncParsableCommand {
	@Option(name: .shortAndLong)
	var hostname: String = "127.0.0.1"

	@Option(name: .shortAndLong)
	var port: Int = 8080

	@Option(name: .long, help: "Bundled CPython runtime root directory (enables Qwen3-TTS service).")
	var pythonRuntimeRoot: String?

	@Option(name: .long, help: "Bundled CPython version under runtime root.")
	var pythonVersion: String = "3.11"

	@Option(name: .long, help: "Startup mode: voice_design | custom_voice")
	var qwenMode: String = QwenSynthesisMode.voiceDesign.rawValue

	@Option(name: .long, help: "Startup model id (optional; defaults by mode).")
	var qwenModelID: String?

	func run() async throws {
		let logger = Logger(label: "TalkToMeKit.TTMServer")
		let startupSelection = try resolveStartupSelection()
		let qwenService = makeQwenServiceIfConfigured(logger: logger, startupSelection: startupSelection)

		let router = Router()
		let api = TTMApi(qwenService: qwenService, logger: logger)
		try api.registerHandlers(on: router)
		let app = Application(
			router: router,
			configuration: .init(address: .hostname(hostname, port: port)),
			logger: logger
		)

		guard let qwenService else {
			try await app.runService()
			return
		}

		let services: [ServiceGroupConfiguration.ServiceConfiguration] = [
			.init(
				service: app,
				successTerminationBehavior: .gracefullyShutdownGroup,
				failureTerminationBehavior: .gracefullyShutdownGroup
			),
			.init(
				service: qwenService,
				successTerminationBehavior: .gracefullyShutdownGroup,
				failureTerminationBehavior: .gracefullyShutdownGroup
			),
		]
		let groupConfiguration = ServiceGroupConfiguration(
			services: services,
			gracefulShutdownSignals: [.sigterm, .sigint],
			logger: logger
		)
		let group = ServiceGroup(configuration: groupConfiguration)
		try await group.run()
	}

	private func resolveStartupSelection() throws -> QwenModelSelection {
		guard let mode = QwenSynthesisMode(rawValue: qwenMode) else {
			throw ValidationError("Invalid --qwen-mode \(qwenMode). Use voice_design or custom_voice.")
		}
		let modelID = qwenModelID.flatMap(QwenModelIdentifier.init(rawValue:))
		if qwenModelID != nil, modelID == nil {
			throw ValidationError("Invalid --qwen-model-id \(qwenModelID ?? "").")
		}
		let selection = QwenModelSelection(mode: mode, modelID: modelID)
		guard selection.modelID.mode == selection.mode else {
			throw ValidationError("Model \(selection.modelID.rawValue) is incompatible with mode \(mode.rawValue).")
		}
		return selection
	}

	private func makeQwenServiceIfConfigured(logger: Logger, startupSelection: QwenModelSelection) -> TTMQwenService? {
		if let pythonRuntimeRoot {
			let configuration = TTMQwenServiceConfiguration.bundledCPython(
				runtimeRoot: URL(fileURLWithPath: pythonRuntimeRoot),
				pythonVersion: pythonVersion,
				startupSelection: startupSelection
			)
			logger.info(
				"Qwen3-TTS service enabled (explicit runtime path)",
				metadata: [
					"pythonRuntimeRoot": "\(pythonRuntimeRoot)",
					"startupMode": "\(startupSelection.mode.rawValue)",
					"startupModelID": "\(startupSelection.modelID.rawValue)",
				]
			)
			return TTMQwenService(configuration: configuration, logger: logger)
		}

		if let configuration = TTMQwenServiceConfiguration.bundledCPythonIfAvailable(
			pythonVersion: pythonVersion,
			startupSelection: startupSelection
		) {
			logger.info(
				"Qwen3-TTS service enabled (bundled runtime autodetected)",
				metadata: [
					"startupMode": "\(startupSelection.mode.rawValue)",
					"startupModelID": "\(startupSelection.modelID.rawValue)",
				]
			)
			return TTMQwenService(configuration: configuration, logger: logger)
		}

		logger.info("Qwen3-TTS service disabled; pass --python-runtime-root or bundle a runtime in TTMPythonRuntimeBundle Resources/Runtime.")
		return nil
	}
}
