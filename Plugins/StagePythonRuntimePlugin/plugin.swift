import Foundation
import PackagePlugin

@main
struct StagePythonRuntimePlugin: CommandPlugin {
	func performCommand(context: PluginContext, arguments: [String]) async throws {
		let packageDirectory = context.package.directoryURL.path
		let userArgs = arguments.filter { $0 != "--" }
		let effectiveArgs = Self.resolveArguments(userArgs)
		let scriptPath = URL(fileURLWithPath: packageDirectory)
			.appendingPathComponent("scripts")
			.appendingPathComponent("stage_python_runtime.sh")
			.path

		guard FileManager.default.fileExists(atPath: scriptPath) else {
			throw StagePythonRuntimePluginError.scriptNotFound(path: scriptPath)
		}

		var finalArgs = ["-py", "python3.11"]
		if !effectiveArgs.isEmpty { finalArgs = effectiveArgs }

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.currentDirectoryURL = URL(fileURLWithPath: packageDirectory)
		process.arguments = [scriptPath] + finalArgs
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError

		try process.run()
		process.waitUntilExit()
		if process.terminationStatus != 0 {
			throw StagePythonRuntimePluginError.failed(code: process.terminationStatus)
		}
	}

	private static func resolveArguments(_ arguments: [String]) -> [String] {
		arguments
	}
}

private enum StagePythonRuntimePluginError: Error, LocalizedError {
	case failed(code: Int32)
	case scriptNotFound(path: String)

	var errorDescription: String? {
		switch self {
		case let .failed(code):
			"stage-python-runtime failed with exit code \(code)"
		case let .scriptNotFound(path):
			"stage-python-runtime script not found at \(path)"
		}
	}
}
