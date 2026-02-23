import Foundation
import Testing

@Suite("TTM stability smoke (integration)", .serialized)
struct StabilitySmokeIntegrationTests {
	@Test("mixed-switch scenario remains stable across mode/model switching")
	func mixedSwitchScenario() async throws {
		guard Self.shouldRun else { return }

		let iterations = Self.envInt("TTM_STABILITY_MIXED_ITERS", default: 20)
		guard let runtimeRoot = Self.runtimeRoot() else { return }
		guard let serverBinary = Self.serverBinary() else { return }
		let port = Self.envInt("TTM_STABILITY_PORT", default: 18091)
		let harness = ServerHarness(serverBinary: serverBinary, runtimeRoot: runtimeRoot, port: port)
		defer { harness.stop() }

		try await harness.start(
			mode: "voice_design",
			modelID: "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
		)

		for i in 1...iterations {
			let loadVD = try await harness.postJSON(
				path: "/model/load",
				json: """
				{"mode":"voice_design","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"}
				"""
			)
			#expect(loadVD == 200 || loadVD == 202)

			let vd = try await harness.postJSONData(
				path: "/synthesize/voice-design",
				json: """
				{"text":"stability mixed vd \(i)","instruct":"Calm concise announcer","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","format":"wav"}
				"""
			)
			#expect(vd.statusCode == 200)
			#expect(Self.looksLikeWav(vd.data))

			let loadCV = try await harness.postJSON(
				path: "/model/load",
				json: """
				{"mode":"custom_voice","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"}
				"""
			)
			#expect(loadCV == 200 || loadCV == 202)

			let cv = try await harness.postJSONData(
				path: "/synthesize/custom-voice",
				json: """
				{"text":"stability mixed cv \(i)","speaker":"serena","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice","format":"wav"}
				"""
			)
			#expect(cv.statusCode == 200)
			#expect(Self.looksLikeWav(cv.data))
		}
	}

	@Test("cold-start voice-design scenario remains stable across restarts")
	func coldStartVoiceDesignScenario() async throws {
		guard Self.shouldRun else { return }

		let iterations = Self.envInt("TTM_STABILITY_COLD_ITERS", default: 8)
		guard let runtimeRoot = Self.runtimeRoot() else { return }
		guard let serverBinary = Self.serverBinary() else { return }
		let port = Self.envInt("TTM_STABILITY_PORT", default: 18091)

		for i in 1...iterations {
			let harness = ServerHarness(serverBinary: serverBinary, runtimeRoot: runtimeRoot, port: port)
			defer { harness.stop() }

			try await harness.start(
				mode: "voice_design",
				modelID: "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
			)

			let vd = try await harness.postJSONData(
				path: "/synthesize/voice-design",
				json: """
				{"text":"stability cold vd \(i)","instruct":"Warm concise voice","language":"English","model_id":"Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign","format":"wav"}
				"""
			)
			#expect(vd.statusCode == 200)
			#expect(Self.looksLikeWav(vd.data))
			#expect(harness.isAlive)
		}
	}

	private static var shouldRun: Bool {
		ProcessInfo.processInfo.environment["TTM_RUN_STABILITY_SMOKE"] == "1"
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

	private static func runtimeRoot() -> URL? {
		let root = repoRoot()
			.appendingPathComponent("Sources")
			.appendingPathComponent("TTMPythonRuntimeBundle")
			.appendingPathComponent("Resources")
			.appendingPathComponent("Runtime")
			.appendingPathComponent("current")

		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			return nil
		}
		return root
	}

	private static func serverBinary() -> URL? {
		if let custom = ProcessInfo.processInfo.environment["TTM_STABILITY_SERVER_BINARY"], !custom.isEmpty {
			let url = URL(fileURLWithPath: custom)
			guard FileManager.default.isExecutableFile(atPath: url.path) else {
				return nil
			}
			return url
		}

		let root = repoRoot()
		let candidates = [
			root.appendingPathComponent(".build").appendingPathComponent("debug").appendingPathComponent("TalkToMeServer"),
			root.appendingPathComponent(".build").appendingPathComponent("arm64-apple-macosx").appendingPathComponent("debug").appendingPathComponent("TalkToMeServer"),
		]
		for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
			return candidate
		}
		return nil
	}

	private static func looksLikeWav(_ data: Data) -> Bool {
		guard data.count >= 12 else { return false }
		let riff = Data("RIFF".utf8)
		let wave = Data("WAVE".utf8)
		return data.starts(with: riff) && data.subdata(in: 8..<12) == wave
	}
}

private final class ServerHarness {
	private let serverBinary: URL
	private let runtimeRoot: URL
	private let port: Int
	private var process: Process?
	private var logHandle: FileHandle?
	private(set) var logURL: URL?

	init(serverBinary: URL, runtimeRoot: URL, port: Int) {
		self.serverBinary = serverBinary
		self.runtimeRoot = runtimeRoot
		self.port = port
	}

	var isAlive: Bool {
		process?.isRunning == true
	}

	func start(mode: String, modelID: String) async throws {
		stop()

		let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("ttm-stability-\(UUID().uuidString).log")
		FileManager.default.createFile(atPath: logURL.path, contents: nil)
		let logHandle = try FileHandle(forWritingTo: logURL)
		self.logURL = logURL
		self.logHandle = logHandle

		let process = Process()
		process.executableURL = serverBinary
		process.arguments = [
			"--hostname", "127.0.0.1",
			"--port", String(port),
			"--python-runtime-root", runtimeRoot.path,
			"--python-version", "3.11",
			"--qwen-mode", mode,
			"--qwen-model-id", modelID,
		]

		var env = ProcessInfo.processInfo.environment
		let runtimeBin = runtimeRoot.appendingPathComponent("bin").path
		let existingPath = env["PATH"] ?? ""
		env["PATH"] = existingPath.isEmpty ? runtimeBin : "\(runtimeBin):\(existingPath)"
		process.environment = env
		process.standardOutput = logHandle
		process.standardError = logHandle

		try process.run()
		self.process = process

		for _ in 1...120 {
			if await healthIsReady() { return }
			try await Task.sleep(for: .milliseconds(250))
		}

		let tail = try logTail()
		Issue.record("TalkToMeServer failed to become ready on port \(port). Log: \(logURL.path)\n\(tail)")
		throw NSError(domain: "StabilitySmoke", code: 1)
	}

	func stop() {
		process?.terminate()
		process = nil
		try? logHandle?.close()
		logHandle = nil
	}

	func postJSON(path: String, json: String) async throws -> Int {
		try await postJSONData(path: path, json: json).statusCode
	}

	func postJSONData(path: String, json: String) async throws -> (statusCode: Int, data: Data) {
		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.httpBody = Data(json.utf8)
		let (data, response) = try await URLSession.shared.data(for: request)
		let code = (response as? HTTPURLResponse)?.statusCode ?? 0
		return (code, data)
	}

	private func healthIsReady() async -> Bool {
		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
		request.httpMethod = "GET"
		do {
			let (_, response) = try await URLSession.shared.data(for: request)
			return (response as? HTTPURLResponse)?.statusCode == 200
		} catch {
			return false
		}
	}

	private func logTail(maxLines: Int = 60) throws -> String {
		guard let logURL else { return "" }
		let text = try String(contentsOf: logURL, encoding: .utf8)
		return text
			.split(separator: "\n", omittingEmptySubsequences: false)
			.suffix(maxLines)
			.joined(separator: "\n")
	}
}
