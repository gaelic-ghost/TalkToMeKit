import Foundation
import Testing

@Suite("Runtime staging script (integration)", .serialized)
struct StagingScriptIntegrationTests {
	@Test("default staging no-ops when runtime, packages, and selected models are already present")
	func defaultStagingNoOpsWhenAllCategoriesPresent() throws {
		let runtimeRoot = try makeTempRuntimeRoot()
		defer { try? FileManager.default.removeItem(at: runtimeRoot) }

		try seedRuntimeCategory(at: runtimeRoot)
		try seedPackagesCategory(at: runtimeRoot)
		try seedModelsCategory(at: runtimeRoot)

		let result = try runStageScript(args: ["--runtime-root", runtimeRoot.path])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("No staging required"))
	}

	@Test("--restage-runtime preserves existing site-packages when package restage is not requested")
	func restageRuntimePreservesPackages() throws {
		let runtimeRoot = try makeTempRuntimeRoot()
		defer { try? FileManager.default.removeItem(at: runtimeRoot) }

		try seedRuntimeCategory(at: runtimeRoot)
		try seedPackagesCategory(at: runtimeRoot)
		try seedModelsCategory(at: runtimeRoot)
		let sentinel = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("python3.11")
			.appendingPathComponent("site-packages")
			.appendingPathComponent("ttm-preserve-sentinel.txt")
		try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

		let result = try runStageScript(args: [
			"--runtime-root", runtimeRoot.path,
			"--no-install-qwen",
			"--noload",
			"--restage-runtime",
		])
		#expect(result.exitCode == 0)
		#expect(FileManager.default.fileExists(atPath: sentinel.path))
	}

	@Test("--restage-packages clears site-packages when package install is disabled")
	func restagePackagesClearsSitePackages() throws {
		let runtimeRoot = try makeTempRuntimeRoot()
		defer { try? FileManager.default.removeItem(at: runtimeRoot) }

		try seedRuntimeCategory(at: runtimeRoot)
		try seedPackagesCategory(at: runtimeRoot)

		let sitePackages = runtimeRoot
			.appendingPathComponent("lib")
			.appendingPathComponent("python3.11")
			.appendingPathComponent("site-packages")

		let result = try runStageScript(args: [
			"--runtime-root", runtimeRoot.path,
			"--no-install-qwen",
			"--noload",
			"--restage-packages",
		])
		#expect(result.exitCode == 0)
		#expect(!FileManager.default.fileExists(atPath: sitePackages.path))
	}

	@Test("--restage-models clears model directories when model download is disabled")
	func restageModelsClearsModelDirectories() throws {
		let runtimeRoot = try makeTempRuntimeRoot()
		defer { try? FileManager.default.removeItem(at: runtimeRoot) }

		try seedRuntimeCategory(at: runtimeRoot)
		try seedModelsCategory(at: runtimeRoot)

		let modelsRoot = runtimeRoot.appendingPathComponent("models")
		let result = try runStageScript(args: [
			"--runtime-root", runtimeRoot.path,
			"--no-install-qwen",
			"--noload",
			"--restage-models",
		])
		#expect(result.exitCode == 0)
		#expect(!FileManager.default.fileExists(atPath: modelsRoot.path))
	}

	@Test("--restage resets all categories while still rebuilding runtime")
	func restageResetsAllCategories() throws {
		let runtimeRoot = try makeTempRuntimeRoot()
		defer { try? FileManager.default.removeItem(at: runtimeRoot) }

		try seedRuntimeCategory(at: runtimeRoot)
		try seedPackagesCategory(at: runtimeRoot)
		try seedModelsCategory(at: runtimeRoot)

		let result = try runStageScript(args: [
			"--runtime-root", runtimeRoot.path,
			"--no-install-qwen",
			"--noload",
			"--restage",
		])
		#expect(result.exitCode == 0)

		let libpython = runtimeRoot.appendingPathComponent("lib").appendingPathComponent("libpython3.11.dylib")
		let stdlib = runtimeRoot.appendingPathComponent("lib").appendingPathComponent("python3.11")
		let sitePackages = stdlib.appendingPathComponent("site-packages")
		let qwenMarker = sitePackages.appendingPathComponent("qwen_tts-0.1.1.dist-info")
		let torchMarker = sitePackages.appendingPathComponent("torch-2.10.0.dist-info")
		let models = runtimeRoot.appendingPathComponent("models")

		#expect(FileManager.default.fileExists(atPath: libpython.path))
		#expect(FileManager.default.fileExists(atPath: stdlib.path))
		#expect(!FileManager.default.fileExists(atPath: qwenMarker.path))
		#expect(!FileManager.default.fileExists(atPath: torchMarker.path))
		#expect(!FileManager.default.fileExists(atPath: models.path))
	}

	private func seedRuntimeCategory(at root: URL) throws {
		let libDir = root.appendingPathComponent("lib")
		let stdlibDir = libDir.appendingPathComponent("python3.11")
		try FileManager.default.createDirectory(at: stdlibDir, withIntermediateDirectories: true)
		let libpython = libDir.appendingPathComponent("libpython3.11.dylib")
		try Data("fake-libpython".utf8).write(to: libpython)
	}

	private func seedPackagesCategory(at root: URL) throws {
		let sitePackages = root
			.appendingPathComponent("lib")
			.appendingPathComponent("python3.11")
			.appendingPathComponent("site-packages")
		try FileManager.default.createDirectory(at: sitePackages, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: sitePackages.appendingPathComponent("qwen_tts-0.1.1.dist-info"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: sitePackages.appendingPathComponent("torch-2.10.0.dist-info"), withIntermediateDirectories: true)
	}

	private func seedModelsCategory(at root: URL) throws {
		let modelsRoot = root.appendingPathComponent("models")
		let modelDirs = [
			"Qwen3-TTS-12Hz-0.6B-CustomVoice",
			"Qwen3-TTS-12Hz-0.6B-Base",
		]
		for dir in modelDirs {
			try FileManager.default.createDirectory(at: modelsRoot.appendingPathComponent(dir), withIntermediateDirectories: true)
		}
	}

	private func makeTempRuntimeRoot() throws -> URL {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("ttm-stage-test-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func runStageScript(args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
		let process = Process()
		let stdout = Pipe()
		let stderr = Pipe()

		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [scriptPath.path] + args
		process.currentDirectoryURL = repoRoot
		process.standardOutput = stdout
		process.standardError = stderr

		try process.run()
		process.waitUntilExit()

		let outData = stdout.fileHandleForReading.readDataToEndOfFile()
		let errData = stderr.fileHandleForReading.readDataToEndOfFile()
		let outText = String(data: outData, encoding: .utf8) ?? ""
		let errText = String(data: errData, encoding: .utf8) ?? ""
		return (process.terminationStatus, outText, errText)
	}

	private var repoRoot: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}

	private var scriptPath: URL {
		repoRoot.appendingPathComponent("scripts").appendingPathComponent("stage_python_runtime.sh")
	}
}
