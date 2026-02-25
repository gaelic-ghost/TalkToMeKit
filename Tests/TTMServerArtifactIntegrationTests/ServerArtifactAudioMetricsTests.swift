import Foundation
import Testing

@Suite("TTM server artifact audio metrics (integration)", .serialized)
struct ServerArtifactAudioMetricsTests {
	@Test("audio metrics: generated custom voice audio stays within baseline envelope")
	func audioMetricsBaselineEnvelope() async throws {
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
			startupTimeoutSeconds: 25,
			environmentOverrides: [
				"TTM_QWEN_DEVICE_MAP": ProcessInfo.processInfo.environment["TTM_TEST_BACKEND"] ?? "cpu",
				"TTM_QWEN_TORCH_DTYPE": ProcessInfo.processInfo.environment["TTM_TEST_DTYPE"] ?? "float32",
			]
		)

		let synth = try await harness.postJSONData(
			path: "/synthesize/custom-voice",
			json: """
			{"text":"Audio metrics baseline check with a short natural sentence.","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
			"""
		)
		#expect(synth.statusCode == 200)
		#expect(synth.data.count > 44)

		let metrics = try WaveMetricsAnalyzer.analyze(synth.data)
		#expect(metrics.channels == 1)
		#expect(metrics.bitsPerSample == 16)
		#expect(metrics.sampleRate >= 16_000)
		#expect(metrics.durationSeconds >= 0.20)
		#expect(metrics.durationSeconds <= 30.0)
		#expect(metrics.rms >= 0.005)
		#expect(metrics.peak <= 1.0)
		#expect(metrics.clippingRatio <= 0.02)
		#expect(metrics.leadingSilenceSeconds <= 2.0)
		#expect(metrics.trailingSilenceSeconds <= 2.0)
	}

	@Test("audio metrics: prompt set remains non-silent and unclipped")
	func audioMetricsPromptSetSanity() async throws {
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
			startupTimeoutSeconds: 25,
			environmentOverrides: [
				"TTM_QWEN_DEVICE_MAP": ProcessInfo.processInfo.environment["TTM_TEST_BACKEND"] ?? "cpu",
				"TTM_QWEN_TORCH_DTYPE": ProcessInfo.processInfo.environment["TTM_TEST_DTYPE"] ?? "float32",
			]
		)

		let prompts = [
			"This is a concise quality check prompt.",
			"Numbers one two three four five in a calm delivery.",
			"A second sentence checks stability and pronunciation clarity.",
		]
		for prompt in prompts {
			let escaped = prompt.replacingOccurrences(of: "\"", with: "\\\"")
			let synth = try await harness.postJSONData(
				path: "/synthesize/custom-voice",
				json: """
				{"text":"\(escaped)","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
				"""
			)
			#expect(synth.statusCode == 200)

			let metrics = try WaveMetricsAnalyzer.analyze(synth.data)
			#expect(metrics.rms >= 0.004)
			#expect(metrics.clippingRatio <= 0.02)
			#expect(metrics.durationSeconds >= 0.15)
		}
	}

	private static var shouldRun: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_ARTIFACT_AUDIO"] == "1"
	}

	private static var port: Int {
		envInt("TTM_ARTIFACT_PORT", default: 18094)
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
			Artifact audio tests were requested (TTM_RUN_ARTIFACT_AUDIO=1), but staged runtime was not found.
			TTM_RUNTIME_DIR: \(custom)
			Expected default runtime root: \(bundledRuntimeRoot.path)
			"""
		)
		throw NSError(domain: "ServerArtifactAudioMetricsTests", code: 2)
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
			Artifact audio tests were requested (TTM_RUN_ARTIFACT_AUDIO=1), but server artifact was not found.
			TTM_ARTIFACT_PATH: \(custom)
			Candidates:
			- \(candidates[0].path)
			- \(candidates[1].path)
			- \(candidates[2].path)
			- \(candidates[3].path)
			Build first with: swift build -c release --product TTMServer
			"""
		)
		throw NSError(domain: "ServerArtifactAudioMetricsTests", code: 3)
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
}
