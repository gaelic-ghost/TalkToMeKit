import Foundation

@main
struct TTMStagePythonRuntimeTool {
	static func main() throws {
		let args = Array(CommandLine.arguments.dropFirst())
		guard let packageDirectory = args.first else {
			fputs("error: missing package directory argument\n", stderr)
			exit(2)
		}

		let userArgs = Array(args.dropFirst()).filter { $0 != "--" }
		let effectiveArgs = try Self.resolveArguments(userArgs)
		let scriptPath = URL(fileURLWithPath: packageDirectory)
			.appendingPathComponent("scripts")
			.appendingPathComponent("stage_python_runtime.sh")
			.path

		var finalArgs = ["--python", "python3.11", "--no-install-qwen"]
		if !effectiveArgs.isEmpty {
			finalArgs = effectiveArgs
		}

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.currentDirectoryURL = URL(fileURLWithPath: packageDirectory)
		process.arguments = [scriptPath] + finalArgs
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError

		try process.run()
		process.waitUntilExit()
		exit(process.terminationStatus)
	}

	private static func resolveArguments(_ arguments: [String]) throws -> [String] {
		let normalized = arguments.filter { $0 != "--allow-network" }
		guard normalized.contains("--restage") else {
			guard normalized.contains("--install-qwen") else {
				return normalized
			}

			guard arguments.contains("--allow-network") else {
				throw ToolError.networkFlagRequired
			}

			return normalized
		}

		var restageArgs = [
			"--restage",
			"--install-qwen",
			"--installer", "uv",
			"--python", "python3.11",
		]
		if !normalized.contains("--include-cv-1.7b") {
			restageArgs.append("--include-cv-1.7b")
		}
		restageArgs.append(contentsOf: normalized.filter { $0 != "--restage" })
		return restageArgs
	}
}

private enum ToolError: Error, LocalizedError {
	case networkFlagRequired

	var errorDescription: String? {
		switch self {
		case .networkFlagRequired:
			"--install-qwen requires --allow-network to make network-dependent staging explicit"
		}
	}
}
