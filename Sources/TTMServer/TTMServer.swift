
// TODO: Impl Hummingbird Server here that uses TTMService

import ArgumentParser
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import ServiceLifecycle
import TTMService

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
	
	func run() async throws {
		let logger = Logger(label: "TalkToMeKit.TTMServer")
		let qwenService = makeQwenServiceIfConfigured(logger: logger)

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

	private func makeQwenServiceIfConfigured(logger: Logger) -> TTMQwenService? {
		if let pythonRuntimeRoot {
			let configuration = TTMQwenServiceConfiguration.bundledCPython(
				runtimeRoot: URL(fileURLWithPath: pythonRuntimeRoot),
				pythonVersion: pythonVersion
			)
			logger.info("Qwen3-TTS service enabled (explicit runtime path)", metadata: ["pythonRuntimeRoot": "\(pythonRuntimeRoot)"])
			return TTMQwenService(configuration: configuration, logger: logger)
		}

		if let configuration = TTMQwenServiceConfiguration.bundledCPythonIfAvailable(pythonVersion: pythonVersion) {
			logger.info("Qwen3-TTS service enabled (bundled runtime autodetected)")
			return TTMQwenService(configuration: configuration, logger: logger)
		}

		logger.info("Qwen3-TTS service disabled; pass --python-runtime-root or bundle a runtime in TTMPythonRuntimeBundle Resources/Runtime.")
		return nil
	}
}
