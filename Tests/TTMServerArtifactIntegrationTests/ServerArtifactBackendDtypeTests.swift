import Foundation
import Testing

@Suite("TTM server artifact backend/dtype (integration)", .serialized)
struct ServerArtifactBackendDtypeTests {
	@Test("backend/dtype matrix: cpu + float32 strict load and synth succeeds")
	func backendDtypeCPUFloat32StrictLoadAndSynth() async throws {
		guard Self.shouldRun else { return }

		let runtimeRoot = try Self.requiredRuntimeRoot()
		guard Self.runtimePrerequisitesPresent(at: runtimeRoot) else { return }

		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: runtimeRoot,
			port: Self.port
		)
		defer { harness.stop() }

		try await harness.start(
			mode: "custom_voice",
			modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
			startupTimeoutSeconds: 20,
			environmentOverrides: [
				"TTM_QWEN_DEVICE_MAP": "cpu",
				"TTM_QWEN_TORCH_DTYPE": "float32",
				"TTM_QWEN_ALLOW_FALLBACK": "0",
			]
		)

		let load = try await harness.postJSONData(
			path: "/model/load",
			json: """
			{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","strict_load":true}
			"""
		)
		#expect(load.statusCode == 200 || load.statusCode == 202)
		if let status = try Self.jsonObject(from: load.data), let strictLoad = status["strict_load"] as? Bool {
			#expect(strictLoad)
		}

		let synth = try await harness.postJSONData(
			path: "/synthesize/custom-voice",
			json: """
			{"text":"artifact backend dtype cpu float32","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
			"""
		)
		#expect(synth.statusCode == 200)
		#expect(Self.looksLikeWav(synth.data))
	}

	@Test("backend/dtype matrix: invalid dtype still serves synth path")
	func backendDtypeInvalidDtypeStillSynthesizes() async throws {
		guard Self.shouldRun else { return }

		let runtimeRoot = try Self.requiredRuntimeRoot()
		guard Self.runtimePrerequisitesPresent(at: runtimeRoot) else { return }

		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: runtimeRoot,
			port: Self.port
		)
		defer { harness.stop() }

		try await harness.start(
			mode: "custom_voice",
			modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
			startupTimeoutSeconds: 20,
			environmentOverrides: [
				"TTM_QWEN_DEVICE_MAP": "cpu",
				"TTM_QWEN_TORCH_DTYPE": "not-a-real-dtype",
				"TTM_QWEN_ALLOW_FALLBACK": "0",
			]
		)

		let load = try await harness.postJSONData(
			path: "/model/load",
			json: """
			{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","strict_load":true}
			"""
		)
		#expect(load.statusCode == 200 || load.statusCode == 202)

		let synth = try await harness.postJSONData(
			path: "/synthesize/custom-voice",
			json: """
			{"text":"artifact backend dtype invalid dtype","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
			"""
		)
		#expect(synth.statusCode == 200)
		#expect(Self.looksLikeWav(synth.data))
	}

	@Test("backend/dtype matrix: invalid backend prevents artifact readiness")
	func backendDtypeInvalidBackendFailsStartup() async throws {
		guard Self.shouldRun else { return }

		let runtimeRoot = try Self.requiredRuntimeRoot()
		guard Self.runtimePrerequisitesPresent(at: runtimeRoot) else { return }

		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: runtimeRoot,
			port: Self.port
		)
		defer { harness.stop() }

		do {
			try await harness.start(
				mode: "custom_voice",
				modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
				startupTimeoutSeconds: 12,
				environmentOverrides: [
					"TTM_QWEN_DEVICE_MAP": "definitely-not-a-real-backend",
					"TTM_QWEN_TORCH_DTYPE": "float32",
					"TTM_QWEN_ALLOW_FALLBACK": "0",
				]
			)
			Issue.record("Expected startup failure with invalid backend")
		} catch {
			let message = String(describing: error)
			#expect(message.contains("failed to become ready") || message.contains("exited before readiness"))
		}
	}

	private static var shouldRun: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_ARTIFACT_FUNCTIONAL"] == "1"
	}

	private static var port: Int {
		envInt("TTM_ARTIFACT_PORT", default: 18093)
	}

	private static func envInt(_ key: String, default defaultValue: Int) -> Int {
		guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 else {
			return defaultValue
		}
		return value
	}

	private static func repoRoot() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}

	private static func requiredRuntimeRoot() throws -> URL {
		if
			let custom = ProcessInfo.processInfo.environment["TTM_RUNTIME_DIR"],
			!custom.isEmpty
		{
			let url = URL(fileURLWithPath: custom)
			var isDirectory: ObjCBool = false
			if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
				return url
			}
		}

		let bundledRuntimeRoot = repoRoot()
			.appendingPathComponent("Sources")
			.appendingPathComponent("TTMPythonRuntimeBundle")
			.appendingPathComponent("Resources")
			.appendingPathComponent("Runtime")
			.appendingPathComponent("current")
		var isDirectory: ObjCBool = false
		if FileManager.default.fileExists(atPath: bundledRuntimeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue {
			return bundledRuntimeRoot
		}

		let custom = ProcessInfo.processInfo.environment["TTM_RUNTIME_DIR"] ?? "<unset>"
		Issue.record(
			"""
			Artifact backend/dtype tests were requested (TTM_RUN_ARTIFACT_FUNCTIONAL=1), but staged runtime was not found.
			TTM_RUNTIME_DIR: \(custom)
			Expected default runtime root: \(bundledRuntimeRoot.path)
			"""
		)
		throw NSError(domain: "ServerArtifactBackendDtypeTests", code: 2)
	}

	private static func requiredServerBinary() throws -> URL {
		if
			let custom = ProcessInfo.processInfo.environment["TTM_ARTIFACT_PATH"],
			!custom.isEmpty
		{
			let url = URL(fileURLWithPath: custom)
			if FileManager.default.isExecutableFile(atPath: url.path) {
				return url
			}
		}

		let root = repoRoot()
		let candidates = [
			root.appendingPathComponent(".build").appendingPathComponent("release").appendingPathComponent("TTMServer"),
			root.appendingPathComponent(".build").appendingPathComponent("arm64-apple-macosx").appendingPathComponent("release").appendingPathComponent("TTMServer"),
			root.appendingPathComponent(".build").appendingPathComponent("release").appendingPathComponent("TalkToMeServer"),
			root.appendingPathComponent(".build").appendingPathComponent("arm64-apple-macosx").appendingPathComponent("release").appendingPathComponent("TalkToMeServer"),
		]
		for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
			return candidate
		}

		let custom = ProcessInfo.processInfo.environment["TTM_ARTIFACT_PATH"] ?? "<unset>"
		Issue.record(
			"""
			Artifact backend/dtype tests were requested (TTM_RUN_ARTIFACT_FUNCTIONAL=1), but server artifact was not found.
			TTM_ARTIFACT_PATH: \(custom)
			Candidates:
			- \(candidates[0].path)
			- \(candidates[1].path)
			- \(candidates[2].path)
			- \(candidates[3].path)
			Build first with: swift build -c release --product TTMServer
			"""
		)
		throw NSError(domain: "ServerArtifactBackendDtypeTests", code: 3)
	}

	private static func runtimePrerequisitesPresent(at runtimeRoot: URL) -> Bool {
		let pythonLibrary = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("libpython3.11.dylib")
		guard FileManager.default.fileExists(atPath: pythonLibrary.path) else {
			return false
		}

		let modelDirectory = runtimeRoot
			.appendingPathComponent("models")
			.appendingPathComponent("Qwen3-TTS-12Hz-0.6B-CustomVoice")
		guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
			return false
		}

		return true
	}

	private static func looksLikeWav(_ data: Data) -> Bool {
		guard data.count >= 12 else { return false }
		let riff = Data("RIFF".utf8)
		let wave = Data("WAVE".utf8)
		return data.starts(with: riff) && data.subdata(in: 8..<12) == wave
	}

	private static func jsonObject(from data: Data) throws -> [String: Any]? {
		guard !data.isEmpty else { return nil }
		let object = try JSONSerialization.jsonObject(with: data)
		return object as? [String: Any]
	}
}
