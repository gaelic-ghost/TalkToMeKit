import Foundation
import Testing

@Suite("TTM server artifact smoke (integration)", .serialized)
struct ServerArtifactSmokeTests {
	@Test("artifact health and synth roundtrip succeeds")
	func artifactHealthAndSynthRoundtrip() async throws {
		guard Self.shouldRun else { return }

		var harness = ArtifactHarness(
			serverBinary: try Self.requiredServerBinary(),
			runtimeRoot: try Self.requiredRuntimeRoot(),
			port: Self.port
		)
		defer { harness.stop() }

		try await harness.start(
			mode: "custom_voice",
			modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
		)
		try await Self.waitForModelReady(harness: harness, timeoutSeconds: 90)

		let health = try await harness.get(path: "/health")
		#expect(health.statusCode == 200)

		let synth = try await harness.postJSONData(
			path: "/synthesize/custom-voice",
			json: """
			{"text":"artifact smoke custom voice check","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
			"""
		)
		#expect(synth.statusCode == 200)
		#expect(Self.looksLikeWav(synth.data))
		#expect(synth.data.count > 44)
		#expect(harness.isAlive)
	}

	private static var shouldRun: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_ARTIFACT_SMOKE"] == "1"
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
			if
				FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
				isDirectory.boolValue,
				Self.runtimePrerequisitesPresent(at: url)
			{
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
		if
			FileManager.default.fileExists(atPath: bundledRuntimeRoot.path, isDirectory: &isDirectory),
			isDirectory.boolValue,
			Self.runtimePrerequisitesPresent(at: bundledRuntimeRoot)
		{
			return bundledRuntimeRoot
		}

		let custom = ProcessInfo.processInfo.environment["TTM_RUNTIME_DIR"] ?? "<unset>"
		Issue.record(
			"""
			Artifact smoke was requested (TTM_RUN_ARTIFACT_SMOKE=1), but staged runtime was not found.
			TTM_RUNTIME_DIR: \(custom)
			Expected default runtime root: \(bundledRuntimeRoot.path)
			"""
		)
		throw NSError(domain: "ServerArtifactSmokeTests", code: 2)
	}

	private static func runtimePrerequisitesPresent(at runtimeRoot: URL) -> Bool {
		let pythonLibrary = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("libpython3.11.dylib")
		guard FileManager.default.fileExists(atPath: pythonLibrary.path) else {
			Issue.record(
				"""
				Artifact smoke prerequisites missing libpython runtime.
				Expected: \(pythonLibrary.path)
				Run: swift package --allow-network-connections all stage-python-runtime
				"""
			)
			return false
		}

		let modelDirectory = runtimeRoot
			.appendingPathComponent("models")
			.appendingPathComponent("Qwen3-TTS-12Hz-0.6B-CustomVoice")
		guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
			Issue.record(
				"""
				Artifact smoke prerequisites missing model directory.
				Expected: \(modelDirectory.path)
				Run: swift package --allow-network-connections all stage-python-runtime
				"""
			)
			return false
		}

		return true
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
				Artifact smoke was requested (TTM_RUN_ARTIFACT_SMOKE=1), but TalkToMeServer release artifact was not found.
				TTM_ARTIFACT_PATH: \(custom)
				Candidates:
				- \(candidates[0].path)
				- \(candidates[1].path)
				- \(candidates[2].path)
				- \(candidates[3].path)
				Build first with: swift build -c release --product TTMServer
				"""
			)
		throw NSError(domain: "ServerArtifactSmokeTests", code: 3)
	}

	private static func looksLikeWav(_ data: Data) -> Bool {
		guard data.count >= 12 else { return false }
		let riff = Data("RIFF".utf8)
		let wave = Data("WAVE".utf8)
		return data.starts(with: riff) && data.subdata(in: 8..<12) == wave
	}

	private static func waitForModelReady(harness: ArtifactHarness, timeoutSeconds: Int) async throws {
		let attempts = max(1, timeoutSeconds * 4)
		for _ in 1...attempts {
			guard harness.isAlive else {
				Issue.record("Artifact smoke server exited before model became ready")
				throw NSError(domain: "ServerArtifactSmokeTests", code: 4)
			}

			let status = try await harness.get(path: "/model/status")
			if status.statusCode == 200, Self.isModelReady(status.data) {
				return
			}
			try await Task.sleep(for: .milliseconds(250))
		}

		Issue.record("Artifact smoke timed out waiting for /model/status ready=true")
		throw NSError(domain: "ServerArtifactSmokeTests", code: 5)
	}

	private static func isModelReady(_ data: Data) -> Bool {
		guard
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let ready = object["ready"] as? Bool
		else {
			return false
		}
		return ready
	}
}
