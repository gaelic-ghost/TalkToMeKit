import Foundation
import Darwin
import Testing
import TTMService
import TTMPythonRuntimeBundle
import TTMService

private enum IntegrationTimeoutError: Error {
	case timedOut
}

private func withTimeout<T: Sendable>(
	seconds: Int,
	operation: @escaping @Sendable () async throws -> T
) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask {
			try await operation()
		}
		group.addTask {
			try await Task.sleep(for: .seconds(seconds))
			throw IntegrationTimeoutError.timedOut
		}
		guard let result = try await group.next() else {
			throw IntegrationTimeoutError.timedOut
		}
		group.cancelAll()
		return result
	}
}

@Suite("TTM Service", .serialized)
struct TTMServiceTests {
	@Test("Bridge starts not ready")
	func bridgeStartsNotReady() async {
		let bridge = TTMPythonBridge()
		let ready = await bridge.isReady
		#expect(!ready)
	}

	@Test("Runtime synthesize before start throws notStarted")
	func runtimeSynthesizeBeforeStartThrows() async {
		let runtime = TTMServiceRuntime()
		do {
			_ = try await runtime.synthesize(.init(text: "hello"))
			Issue.record("Expected synthesize to throw when runtime is not started")
		} catch let error as TTMServiceRuntimeError {
			#expect(error == .notStarted)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
	}

	@Test("Runtime status starts stopped")
	func runtimeStatusStartsStopped() async {
		let runtime = TTMServiceRuntime()
		let status = await runtime.status()
		#expect(!status.started)
		#expect(!status.ready)
		#expect(!status.modelLoaded)
		#expect(status.bridgeStatus == nil)
	}

	@Test("Runtime start fails for invalid local runtime")
	func runtimeStartFailsForInvalidRuntime() async {
		let provider = TTMLocalRuntimeAssetProvider(runtimeRoot: URL(fileURLWithPath: "/tmp/does-not-exist"))
		let runtime = TTMServiceRuntime(
			configuration: .init(
				assetProvider: provider,
				startupTimeoutSeconds: 1
			)
		)
		do {
			try await runtime.start()
			Issue.record("Expected runtime start to fail for invalid runtime path")
		} catch let error as TTMServiceRuntimeError {
			#expect(error == .runtimeUnavailable)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
		await runtime.stop()
	}

	@Test("First-launch provider invokes download hook when runtime missing")
	func firstLaunchProviderInvokesDownloadHook() async {
		let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("ttm-first-launch-\(UUID().uuidString)", isDirectory: true)
		let marker = tempRoot.appendingPathComponent("download-called.txt")
		defer {
			try? FileManager.default.removeItem(at: tempRoot)
		}
		try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

		let provider = TTMFirstLaunchDownloadAssetProvider(
			runtimeRoot: tempRoot,
			pythonVersion: "3.11",
			downloadIfNeeded: { _, _ in
				FileManager.default.createFile(atPath: marker.path, contents: Data("ok".utf8))
			}
		)

		let runtime = TTMServiceRuntime(
			configuration: .init(
				assetProvider: provider,
				startupTimeoutSeconds: 1
			)
		)
		do {
			try await runtime.start()
			Issue.record("Expected first-launch provider start to fail without prepared runtime")
		} catch let error as TTMServiceRuntimeError {
			#expect(error == .runtimeUnavailable)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}

		#expect(FileManager.default.fileExists(atPath: marker.path))
		await runtime.stop()
	}

	@Test("Bridge status starts empty")
	func bridgeStatusStartsEmpty() async {
		let bridge = TTMPythonBridge()
		let status = await bridge.status()
		#expect(!status.runtimeInitialized)
		#expect(!status.moduleLoaded)
		#expect(!status.modelLoaded)
		#expect(!status.ready)
		#expect(status.lastError == nil)
	}

	@Test("Bridge synthesize before initialize throws notInitialized")
	func bridgeSynthesizeWithoutInitializeThrows() async {
		let bridge = TTMPythonBridge()
		do {
			_ = try await bridge.synthesize(
				.customVoice(
					text: "hello",
					speaker: "serena",
					language: "English",
					modelID: .customVoice0_6B
				)
			)
			Issue.record("Expected synthesize to throw when bridge is uninitialized")
		} catch let error as TTMPythonBridgeError {
			#expect(error == .notInitialized)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
	}

	@Test("Bridge model starts unloaded")
	func bridgeModelStartsUnloaded() async {
		let bridge = TTMPythonBridge()
		let modelLoaded = await bridge.isModelLoaded()
		#expect(!modelLoaded)
	}

	@Test("Bridge load model before initialize throws notInitialized")
	func bridgeLoadModelWithoutInitializeThrows() async {
		let bridge = TTMPythonBridge()
		do {
			_ = try await bridge.loadModel(selection: .defaultVoiceDesign)
			Issue.record("Expected loadModel to throw when bridge is uninitialized")
		} catch let error as TTMPythonBridgeError {
			#expect(error == .notInitialized)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
	}

	@Test("Bundled CPython config resolves canonical runtime paths")
	func bundledCPythonConfigurationPaths() {
		let runtimeRoot = URL(fileURLWithPath: "/opt/talktome/python-arm64")
		let config = TTMQwenServiceConfiguration.bundledCPython(
			runtimeRoot: runtimeRoot,
			pythonVersion: "3.11"
		)

		#expect(config.runtime.pythonLibraryPath == "/opt/talktome/python-arm64/lib/libpython3.11.dylib")
		#expect(config.runtime.pythonHome == "/opt/talktome/python-arm64")
		#expect(config.runtime.moduleSearchPaths.contains("/opt/talktome/python-arm64/lib/python3.11"))
		#expect(config.runtime.moduleSearchPaths.contains("/opt/talktome/python-arm64/lib/python3.11/site-packages"))
	}

	@Test("Bundled CPython auto-discovery is optional")
	func bundledCPythonAutoDiscoveryOptional() {
		let runtime = TTMPythonRuntimeBundleLocator.bundledRuntime(pythonVersion: "3.11")
		if runtime == nil {
			let config = TTMQwenServiceConfiguration.bundledCPythonIfAvailable(pythonVersion: "3.11")
			#expect(config == nil)
		} else {
			let config = TTMQwenServiceConfiguration.bundledCPythonIfAvailable(pythonVersion: "3.11")
			#expect(config != nil)
		}
	}

	@Test(
		"Bridge integrates VoiceDesign 1.7B when bundled model is available",
		.enabled(if: Self.shouldRunBundledModelIntegration, "Set TTM_RUN_BUNDLED_MODEL_INTEGRATION=1")
	)
	func bridgeIntegratesVoiceDesign17BIfAvailable() async {
		await assertBundledRuntimeSynthesisIfModelAvailable(
			selection: .init(mode: .voiceDesign, modelID: .voiceDesign1_7B),
			request: .voiceDesign(
				text: "Integration smoke test for voice design",
				instruct: "Warm narrator voice",
				language: "English",
				modelID: .voiceDesign1_7B
			)
		)
	}

	@Test(
		"Bridge integrates CustomVoice 0.6B when bundled model is available",
		.enabled(if: Self.shouldRunBundledModelIntegration, "Set TTM_RUN_BUNDLED_MODEL_INTEGRATION=1")
	)
	func bridgeIntegratesCustomVoice06BIfAvailable() async {
		await assertBundledRuntimeSynthesisIfModelAvailable(
			selection: .init(mode: .customVoice, modelID: .customVoice0_6B),
			request: .customVoice(
				text: "Integration smoke test for custom voice",
				speaker: "serena",
				language: "English",
				modelID: .customVoice0_6B
			)
		)
	}

	@Test(
		"Bridge integrates CustomVoice 1.7B when bundled model is available",
		.enabled(if: Self.shouldRunBundledModelIntegration, "Set TTM_RUN_BUNDLED_MODEL_INTEGRATION=1")
	)
	func bridgeIntegratesCustomVoice17BIfAvailable() async {
		await assertBundledRuntimeSynthesisIfModelAvailable(
			selection: .init(mode: .customVoice, modelID: .customVoice1_7B),
			request: .customVoice(
				text: "Integration smoke test for custom voice one point seven",
				speaker: "serena",
				language: "English",
				modelID: .customVoice1_7B
			)
		)
	}

	private func assertBundledRuntimeSynthesisIfModelAvailable(
		selection: QwenModelSelection,
		request: QwenSynthesisRequest
	) async {
		guard
			let bundledRuntime = TTMPythonRuntimeBundleLocator.bundledRuntime(pythonVersion: "3.11"),
			let modulePath = TTMPythonBridgeResources.pythonModulesPath
		else {
			return
		}

		let bundledModelPath = bundledRuntime.rootURL
			.appendingPathComponent("models")
			.appendingPathComponent(selection.modelID.rawValue.split(separator: "/").last.map(String.init) ?? "")
		guard FileManager.default.fileExists(atPath: bundledModelPath.path) else {
			return
		}

		let originalDeviceMap = getenv("TTM_QWEN_DEVICE_MAP").map { String(cString: $0) }
		let originalDType = getenv("TTM_QWEN_TORCH_DTYPE").map { String(cString: $0) }
		let originalAllowFallback = getenv("TTM_QWEN_ALLOW_FALLBACK").map { String(cString: $0) }
		setenv("TTM_QWEN_DEVICE_MAP", "cpu", 1)
		setenv("TTM_QWEN_TORCH_DTYPE", "float32", 1)
		setenv("TTM_QWEN_ALLOW_FALLBACK", "0", 1)
		defer {
			if let originalDeviceMap {
				setenv("TTM_QWEN_DEVICE_MAP", originalDeviceMap, 1)
			} else {
				unsetenv("TTM_QWEN_DEVICE_MAP")
			}
			if let originalDType {
				setenv("TTM_QWEN_TORCH_DTYPE", originalDType, 1)
			} else {
				unsetenv("TTM_QWEN_TORCH_DTYPE")
			}
			if let originalAllowFallback {
				setenv("TTM_QWEN_ALLOW_FALLBACK", originalAllowFallback, 1)
			} else {
				unsetenv("TTM_QWEN_ALLOW_FALLBACK")
			}
		}

		let bridge = TTMPythonBridge()
		let configuration = PythonRuntimeConfiguration(
			pythonLibraryPath: bundledRuntime.libraryURL.path,
			pythonHome: bundledRuntime.rootURL.path,
			moduleSearchPaths: bundledRuntime.moduleSearchPaths.map(\.path) + [modulePath],
			qwenModule: "qwen_tts_runner"
		)

		do {
			try await bridge.initialize(configuration: configuration)
			try await bridge.importQwenModule()
			let loaded = try await withTimeout(seconds: 90) {
				try await bridge.loadModel(selection: selection, strict: true)
			}
			#expect(loaded)
			let status = await bridge.status()
			#expect(status.modelLoaded)
			#expect(status.activeMode == selection.mode)
			#expect(status.activeModelID == selection.modelID)
			#expect(status.strictLoad)
			#expect(!status.fallbackApplied)

			let audio = try await withTimeout(seconds: 90) {
				try await bridge.synthesize(request)
			}
			#expect(!audio.isEmpty)
			#expect(audio.count > 44)
		} catch {
			Issue.record("Bundled runtime integration failed: \(error)")
		}
		do {
			_ = try await bridge.unloadModel()
		} catch {
			// Best-effort unload before bridge shutdown to reduce native teardown races.
		}
		await bridge.shutdown()
	}

	@Test("Backend/dtype matrix: cpu + float32 strict load and synth succeeds")
	func backendDtypeCPUFloat32() async throws {
		guard Self.shouldRunBackendDtypeMatrix else { return }
		let prerequisites = try Self.requireBackendDtypePrerequisites()
		let selection = QwenModelSelection(mode: .customVoice, modelID: .customVoice0_6B)
		let request = QwenSynthesisRequest.customVoice(
			text: "backend dtype cpu float32 check",
			speaker: "serena",
			language: "English",
			modelID: .customVoice0_6B
		)

		try await withEnvironment([
			"TTM_QWEN_DEVICE_MAP": "cpu",
			"TTM_QWEN_TORCH_DTYPE": "float32",
			"TTM_QWEN_ALLOW_FALLBACK": "0",
		]) {
			try await withManagedBridge { bridge in
				let configuration = PythonRuntimeConfiguration(
					pythonLibraryPath: prerequisites.runtime.libraryURL.path,
					pythonHome: prerequisites.runtime.rootURL.path,
					moduleSearchPaths: prerequisites.runtime.moduleSearchPaths.map(\.path) + [prerequisites.modulePath],
					qwenModule: "qwen_tts_runner"
				)

				try await withTimeout(seconds: 90) {
					try await bridge.initialize(configuration: configuration)
					try await bridge.importQwenModule()
					let loaded = try await bridge.loadModel(selection: selection, strict: true)
					#expect(loaded)
					let audio = try await bridge.synthesize(request)
					#expect(audio.count > 44)
					#expect(audio.starts(with: Data("RIFF".utf8)))
				}

				let status = await bridge.status()
				#expect(status.modelLoaded)
				#expect(status.strictLoad)
				#expect(status.activeModelID == .customVoice0_6B)
				#expect(!status.fallbackApplied)
			}
		}
	}

	@Test("Backend/dtype matrix: auto backend with unset dtype strict load and synth succeeds")
	func backendDtypeAutoUnsetDtype() async throws {
		guard Self.shouldRunBackendDtypeMatrix else { return }
		let prerequisites = try Self.requireBackendDtypePrerequisites()
		let selection = QwenModelSelection(mode: .customVoice, modelID: .customVoice0_6B)
		let request = QwenSynthesisRequest.customVoice(
			text: "backend dtype auto unset check",
			speaker: "serena",
			language: "English",
			modelID: .customVoice0_6B
		)

		try await withEnvironment([
			"TTM_QWEN_DEVICE_MAP": "auto",
			"TTM_QWEN_TORCH_DTYPE": nil,
			"TTM_QWEN_ALLOW_FALLBACK": "0",
		]) {
			try await withManagedBridge { bridge in
				let configuration = PythonRuntimeConfiguration(
					pythonLibraryPath: prerequisites.runtime.libraryURL.path,
					pythonHome: prerequisites.runtime.rootURL.path,
					moduleSearchPaths: prerequisites.runtime.moduleSearchPaths.map(\.path) + [prerequisites.modulePath],
					qwenModule: "qwen_tts_runner"
				)

				try await withTimeout(seconds: 90) {
					try await bridge.initialize(configuration: configuration)
					try await bridge.importQwenModule()
					let loaded = try await bridge.loadModel(selection: selection, strict: true)
					#expect(loaded)
					let audio = try await bridge.synthesize(request)
					#expect(audio.count > 44)
					#expect(audio.starts(with: Data("RIFF".utf8)))
				}

				let status = await bridge.status()
				#expect(status.modelLoaded)
				#expect(status.strictLoad)
				#expect(status.activeModelID == .customVoice0_6B)
				#expect(!status.fallbackApplied)
			}
		}
	}

	@Test("Backend/dtype matrix: invalid dtype falls back to float32 behavior")
	func backendDtypeInvalidDtypeFallsBack() async throws {
		guard Self.shouldRunBackendDtypeMatrix else { return }
		let prerequisites = try Self.requireBackendDtypePrerequisites()
		let selection = QwenModelSelection(mode: .customVoice, modelID: .customVoice0_6B)
		let request = QwenSynthesisRequest.customVoice(
			text: "backend dtype invalid fallback check",
			speaker: "serena",
			language: "English",
			modelID: .customVoice0_6B
		)

		try await withEnvironment([
			"TTM_QWEN_DEVICE_MAP": "cpu",
			"TTM_QWEN_TORCH_DTYPE": "not-a-real-dtype",
			"TTM_QWEN_ALLOW_FALLBACK": "0",
		]) {
			try await withManagedBridge { bridge in
				let configuration = PythonRuntimeConfiguration(
					pythonLibraryPath: prerequisites.runtime.libraryURL.path,
					pythonHome: prerequisites.runtime.rootURL.path,
					moduleSearchPaths: prerequisites.runtime.moduleSearchPaths.map(\.path) + [prerequisites.modulePath],
					qwenModule: "qwen_tts_runner"
				)

				try await withTimeout(seconds: 90) {
					try await bridge.initialize(configuration: configuration)
					try await bridge.importQwenModule()
					let loaded = try await bridge.loadModel(selection: selection, strict: true)
					#expect(loaded)
					let audio = try await bridge.synthesize(request)
					#expect(audio.count > 44)
					#expect(audio.starts(with: Data("RIFF".utf8)))
				}

				let status = await bridge.status()
				#expect(status.modelLoaded)
				#expect(status.lastError == nil)
			}
		}
	}

	@Test("Backend/dtype matrix: invalid backend value fails strict model load")
	func backendDtypeInvalidBackendFailsStrictLoad() async throws {
		guard Self.shouldRunBackendDtypeMatrix else { return }
		let prerequisites = try Self.requireBackendDtypePrerequisites()
		let selection = QwenModelSelection(mode: .customVoice, modelID: .customVoice0_6B)

		try await withEnvironment([
			"TTM_QWEN_DEVICE_MAP": "definitely-not-a-real-backend",
			"TTM_QWEN_TORCH_DTYPE": "float32",
			"TTM_QWEN_ALLOW_FALLBACK": "0",
		]) {
			try await withManagedBridge { bridge in
				let configuration = PythonRuntimeConfiguration(
					pythonLibraryPath: prerequisites.runtime.libraryURL.path,
					pythonHome: prerequisites.runtime.rootURL.path,
					moduleSearchPaths: prerequisites.runtime.moduleSearchPaths.map(\.path) + [prerequisites.modulePath],
					qwenModule: "qwen_tts_runner"
				)

				try await withTimeout(seconds: 90) {
					try await bridge.initialize(configuration: configuration)
					try await bridge.importQwenModule()
					let loaded = try await bridge.loadModel(selection: selection, strict: true)
					#expect(!loaded)
				}

				let status = await bridge.status()
				#expect(!status.modelLoaded)
				#expect(status.strictLoad)
				#expect(status.lastError != nil)
			}
		}
	}

	private struct BackendDtypePrerequisites {
		var runtime: TTMPythonBundledRuntime
		var modulePath: String
	}

	private static var shouldRunBundledModelIntegration: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_BUNDLED_MODEL_INTEGRATION"] == "1"
	}

	private static var shouldRunBackendDtypeMatrix: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_BACKEND_DTYPE_MATRIX"] == "1"
	}

	private static func requireBackendDtypePrerequisites() throws -> BackendDtypePrerequisites {
		guard let runtime = TTMPythonRuntimeBundleLocator.bundledRuntime(pythonVersion: "3.11") else {
			Issue.record(
				"""
				Backend/dtype matrix was requested (TTM_RUN_BACKEND_DTYPE_MATRIX=1), but bundled runtime was not found.
				Expected Runtime/current under TTMPythonRuntimeBundle resources.
				"""
			)
			throw NSError(domain: "BackendDtypeMatrix", code: 1)
		}
		guard let modulePath = TTMPythonBridgeResources.pythonModulesPath else {
			Issue.record(
				"""
				Backend/dtype matrix was requested (TTM_RUN_BACKEND_DTYPE_MATRIX=1), but Python bridge modules path could not be resolved.
				"""
			)
			throw NSError(domain: "BackendDtypeMatrix", code: 2)
		}
		let modelPath = runtime.rootURL
			.appendingPathComponent("models")
			.appendingPathComponent("Qwen3-TTS-12Hz-0.6B-CustomVoice")
			.path
		guard FileManager.default.fileExists(atPath: modelPath) else {
			Issue.record(
				"""
				Backend/dtype matrix was requested (TTM_RUN_BACKEND_DTYPE_MATRIX=1), but required model is missing.
				Expected model directory: \(modelPath)
				"""
			)
			throw NSError(domain: "BackendDtypeMatrix", code: 3)
		}
		return .init(runtime: runtime, modulePath: modulePath)
	}

	private func withManagedBridge<T>(
		operation: @escaping @Sendable (TTMPythonBridge) async throws -> T
	) async throws -> T {
		let bridge = TTMPythonBridge()
		do {
			let result = try await operation(bridge)
			await bridge.shutdown()
			return result
		} catch {
			await bridge.shutdown()
			throw error
		}
	}

	private func withEnvironment<T>(
		_ overrides: [String: String?],
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		var original: [String: String?] = [:]
		for key in overrides.keys {
			if let raw = getenv(key) {
				original[key] = String(cString: raw)
			} else {
				original[key] = nil
			}
		}

		for (key, value) in overrides {
			if let value {
				setenv(key, value, 1)
			} else {
				unsetenv(key)
			}
		}

		defer {
			for (key, value) in original {
				if let value {
					setenv(key, value, 1)
				} else {
					unsetenv(key)
				}
			}
		}

		return try await operation()
	}
}
