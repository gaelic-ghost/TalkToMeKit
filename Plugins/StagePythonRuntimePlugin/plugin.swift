import Foundation
import PackagePlugin

@main
struct StagePythonRuntimePlugin: CommandPlugin {
	func performCommand(context: PluginContext, arguments: [String]) async throws {
		let tool = try context.tool(named: "TTMStagePythonRuntimeTool")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: tool.url.path)
		process.currentDirectoryURL = URL(fileURLWithPath: context.package.directoryURL.path)
		process.arguments = [context.package.directoryURL.path] + arguments

		try process.run()
		process.waitUntilExit()
		if process.terminationStatus != 0 {
			throw StagePythonRuntimePluginError.failed(code: process.terminationStatus)
		}
	}
}

private enum StagePythonRuntimePluginError: Error, CustomStringConvertible {
	case failed(code: Int32)

	var description: String {
		switch self {
		case let .failed(code):
			"stage-python-runtime failed with exit code \(code)"
		}
	}
}
