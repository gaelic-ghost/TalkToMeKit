import Foundation
import Darwin
import Testing
import TTMPythonBridge
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
			_ = try await bridge.synthesize(.init(text: "hello"))
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
			_ = try await bridge.loadModel()
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

	@Test("Bridge can initialize and synthesize with bundled runtime when available")
	func bridgeIntegrationWithBundledRuntimeIfAvailable() async {
		guard
			let bundledRuntime = TTMPythonRuntimeBundleLocator.bundledRuntime(pythonVersion: "3.11"),
			let modulePath = TTMPythonBridgeResources.pythonModulesPath
		else {
			return
		}

		setenv("TTM_QWEN_ALLOW_FALLBACK", "1", 1)
		defer { unsetenv("TTM_QWEN_ALLOW_FALLBACK") }
		let localModelPath = bundledRuntime.rootURL
			.appendingPathComponent("models")
			.appendingPathComponent("Qwen3-TTS-12Hz-0.6B-CustomVoice")
		let hasLocalModel = FileManager.default.fileExists(atPath: localModelPath.path)
		if FileManager.default.fileExists(atPath: localModelPath.path) {
			setenv("TTM_QWEN_LOCAL_MODEL_PATH", localModelPath.path, 1)
		}
		defer {
			if hasLocalModel {
				unsetenv("TTM_QWEN_LOCAL_MODEL_PATH")
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
				try await bridge.loadModel()
			}
			#expect(loaded)

			let audio = try await withTimeout(seconds: 90) {
				try await bridge.synthesize(.init(text: "Integration smoke test"))
			}
			#expect(!audio.isEmpty)
			#expect(audio.count > 44)
			await bridge.shutdown()
		} catch {
			Issue.record("Bundled runtime integration failed: \(error)")
		}
	}
}
