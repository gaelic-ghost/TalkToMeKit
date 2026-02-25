import Foundation

struct ArtifactHarness {
	let serverBinary: URL
	let runtimeRoot: URL
	let port: Int

	private(set) var process: Process?
	private(set) var logHandle: FileHandle?
	private(set) var logURL: URL?

	var isAlive: Bool {
		process?.isRunning == true
	}

	mutating func start(
		mode: String,
		modelID: String,
		startupTimeoutSeconds: Int = 30,
		environmentOverrides: [String: String] = [:]
	) async throws {
		stop()

		let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("ttm-artifact-smoke-\(UUID().uuidString).log")
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
		for (key, value) in environmentOverrides {
			env[key] = value
		}
		process.environment = env
		process.standardOutput = logHandle
		process.standardError = logHandle

		try process.run()
		self.process = process

		let pollCount = max(1, startupTimeoutSeconds * 4)
		for _ in 1...pollCount {
			if await healthIsReady() {
				return
			}
			if process.isRunning == false {
				throw ArtifactHarnessError.serverExited(
					status: process.terminationStatus,
					logPath: logURL.path,
					tail: try logTail()
				)
			}
			try await Task.sleep(for: .milliseconds(250))
		}

		throw ArtifactHarnessError.serverDidNotBecomeReady(logPath: logURL.path, tail: try logTail())
	}

	mutating func stop() {
		process?.terminate()
		process = nil
		try? logHandle?.close()
		logHandle = nil
	}

	func get(path: String) async throws -> (statusCode: Int, data: Data) {
		let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
		let (data, response) = try await URLSession.shared.data(for: request)
		let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
		return (statusCode, data)
	}

	func postJSONData(path: String, json: String) async throws -> (statusCode: Int, data: Data) {
		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.httpBody = Data(json.utf8)
		let (data, response) = try await URLSession.shared.data(for: request)
		let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
		return (statusCode, data)
	}

	private func healthIsReady() async -> Bool {
		do {
			let response = try await get(path: "/health")
			return response.statusCode == 200
		} catch {
			return false
		}
	}

	private func logTail(limit: Int = 2_000) throws -> String {
		guard let logURL else { return "<no log file>" }
		let data = try Data(contentsOf: logURL)
		let text = String(decoding: data, as: UTF8.self)
		if text.count <= limit {
			return text
		}
		let suffix = text.suffix(limit)
		return "...\n\(suffix)"
	}
}

enum ArtifactHarnessError: Error, CustomStringConvertible {
	case serverDidNotBecomeReady(logPath: String, tail: String)
	case serverExited(status: Int32, logPath: String, tail: String)

	var description: String {
		switch self {
		case let .serverDidNotBecomeReady(logPath, tail):
			return "TalkToMeServer failed to become ready. Log: \(logPath)\n\(tail)"
		case let .serverExited(status, logPath, tail):
			return "TalkToMeServer exited before readiness. Status: \(status). Log: \(logPath)\n\(tail)"
		}
	}
}
