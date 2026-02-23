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

	@Test("Bridge integrates VoiceDesign 1.7B when bundled model is available")
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

	@Test("Bridge integrates CustomVoice 0.6B when bundled model is available")
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

	@Test("Bridge integrates CustomVoice 1.7B when bundled model is available")
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

		setenv("TTM_QWEN_ALLOW_FALLBACK", "1", 1)
		defer { unsetenv("TTM_QWEN_ALLOW_FALLBACK") }
		let bundledModelPath = bundledRuntime.rootURL
			.appendingPathComponent("models")
			.appendingPathComponent(selection.modelID.rawValue.split(separator: "/").last.map(String.init) ?? "")
		guard FileManager.default.fileExists(atPath: bundledModelPath.path) else {
			return
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
				try await bridge.loadModel(selection: selection)
			}
			#expect(loaded)

			let audio = try await withTimeout(seconds: 90) {
				try await bridge.synthesize(request)
			}
			#expect(!audio.isEmpty)
			#expect(audio.count > 44)
			await bridge.shutdown()
		} catch {
			Issue.record("Bundled runtime integration failed: \(error)")
		}
	}
}
