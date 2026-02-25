import Foundation
import Testing

@Suite("TTM server artifact staging (integration)", .serialized)
struct ServerArtifactStagingTests {
	@Test("artifact starts and synthesizes when runtime and model are staged")
	func artifactStartsAndSynthesizesWithStagedAssets() async throws {
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
			startupTimeoutSeconds: 20
		)

		let health = try await harness.get(path: "/health")
		#expect(health.statusCode == 200)

		let synth = try await harness.postJSONData(
			path: "/synthesize/custom-voice",
			json: """
			{"text":"artifact functional staging check","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
			"""
		)
		#expect(synth.statusCode == 200)
		#expect(Self.looksLikeWav(synth.data))
		#expect(synth.data.count > 44)
		#expect(harness.isAlive)
	}

	@Test("artifact fails clearly when runtime root is missing")
	func artifactFailsWhenRuntimeRootMissing() async throws {
		guard Self.shouldRun else { return }

		let missingRuntimeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("ttm-missing-runtime-\(UUID().uuidString)")
		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: missingRuntimeRoot,
			port: Self.port
		)
		defer { harness.stop() }

		do {
			try await harness.start(
				mode: "custom_voice",
				modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
				startupTimeoutSeconds: 8
			)
			Issue.record("Expected startup failure for missing runtime root")
		} catch {
			let message = String(describing: error)
			#expect(message.contains("failed to become ready") || message.contains("exited before readiness"))
		}
	}

	@Test("artifact fails clearly when startup model ID is invalid")
	func artifactFailsWhenStartupModelInvalid() async throws {
		guard Self.shouldRun else { return }

		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: try Self.requiredRuntimeRoot(),
			port: Self.port
		)
		defer { harness.stop() }

		do {
			try await harness.start(
				mode: "custom_voice",
				modelID: "Qwen/Definitely-Not-A-Real-Qwen3-TTS-Model",
				startupTimeoutSeconds: 12
			)
			Issue.record("Expected startup failure for invalid startup model")
		} catch {
			let message = String(describing: error)
			#expect(message.contains("failed to become ready") || message.contains("exited before readiness"))
		}
	}

	private static var shouldRun: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_ARTIFACT_FUNCTIONAL"] == "1"
	}

	private static var port: Int {
		envInt("TTM_ARTIFACT_PORT", default: 18092)
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
			Artifact functional tests were requested (TTM_RUN_ARTIFACT_FUNCTIONAL=1), but staged runtime was not found.
			TTM_RUNTIME_DIR: \(custom)
			Expected default runtime root: \(bundledRuntimeRoot.path)
			"""
		)
		throw NSError(domain: "ServerArtifactStagingTests", code: 2)
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
			Artifact functional tests were requested (TTM_RUN_ARTIFACT_FUNCTIONAL=1), but server artifact was not found.
			TTM_ARTIFACT_PATH: \(custom)
			Candidates:
			- \(candidates[0].path)
			- \(candidates[1].path)
			- \(candidates[2].path)
			- \(candidates[3].path)
			Build first with: swift build -c release --product TTMServer
			"""
		)
		throw NSError(domain: "ServerArtifactStagingTests", code: 3)
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
}
