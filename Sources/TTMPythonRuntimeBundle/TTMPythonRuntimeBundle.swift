import Foundation

public struct TTMPythonBundledRuntime: Sendable {
	public let rootURL: URL
	public let libraryURL: URL
	public let moduleSearchPaths: [URL]
	public let pythonVersion: String

	public init(rootURL: URL, libraryURL: URL, moduleSearchPaths: [URL], pythonVersion: String) {
		self.rootURL = rootURL
		self.libraryURL = libraryURL
		self.moduleSearchPaths = moduleSearchPaths
		self.pythonVersion = pythonVersion
	}
}

public enum TTMPythonRuntimeBundleLocator {
	public static func bundledRuntime(pythonVersion: String = "3.11") -> TTMPythonBundledRuntime? {
		guard let resourceURL = Bundle.module.resourceURL else {
			return nil
		}

		let runtimeContainer = resourceURL.appendingPathComponent("Runtime", isDirectory: true)
		let candidates = [
			runtimeContainer.appendingPathComponent("python\(pythonVersion)-arm64", isDirectory: true),
			runtimeContainer.appendingPathComponent("python\(pythonVersion)", isDirectory: true),
			runtimeContainer.appendingPathComponent("current", isDirectory: true),
		]

		for candidate in candidates {
			if let runtime = validateRuntime(at: candidate, preferredPythonVersion: pythonVersion) {
				return runtime
			}
		}

		return nil
	}

	private static func validateRuntime(at rootURL: URL, preferredPythonVersion: String) -> TTMPythonBundledRuntime? {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: rootURL.path) else {
			return nil
		}

		let libRoot = rootURL.appendingPathComponent("lib", isDirectory: true)
		guard fileManager.fileExists(atPath: libRoot.path) else {
			return nil
		}

		let exactLib = libRoot.appendingPathComponent("libpython\(preferredPythonVersion).dylib", isDirectory: false)
		if fileManager.fileExists(atPath: exactLib.path) {
			let stdlib = libRoot.appendingPathComponent("python\(preferredPythonVersion)", isDirectory: true)
			if let runtime = buildRuntime(rootURL: rootURL, libraryURL: exactLib, stdlibURL: stdlib, pythonVersion: preferredPythonVersion) {
				return runtime
			}
		}

		guard let discovered = discoverAnyPythonRuntime(rootURL: rootURL, libRoot: libRoot) else {
			return nil
		}
		return discovered
	}

	private static func discoverAnyPythonRuntime(rootURL: URL, libRoot: URL) -> TTMPythonBundledRuntime? {
		let fileManager = FileManager.default
		guard let entries = try? fileManager.contentsOfDirectory(at: libRoot, includingPropertiesForKeys: nil) else {
			return nil
		}

		let libCandidates = entries
			.filter { $0.lastPathComponent.hasPrefix("libpython") && $0.pathExtension == "dylib" }
			.sorted { $0.lastPathComponent > $1.lastPathComponent }

		for libURL in libCandidates {
			guard let version = parseVersion(fromLibraryName: libURL.lastPathComponent) else {
				continue
			}
			let stdlibURL = libRoot.appendingPathComponent("python\(version)", isDirectory: true)

			if let runtime = buildRuntime(rootURL: rootURL, libraryURL: libURL, stdlibURL: stdlibURL, pythonVersion: version) {
				return runtime
			}
		}

		return nil
	}

	private static func buildRuntime(
		rootURL: URL,
		libraryURL: URL,
		stdlibURL: URL,
		pythonVersion: String
	) -> TTMPythonBundledRuntime? {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: libraryURL.path) else {
			return nil
		}
		guard fileManager.fileExists(atPath: stdlibURL.path) else {
			return nil
		}

		let sitePackagesURL = stdlibURL.appendingPathComponent("site-packages", isDirectory: true)
		let moduleSearchPaths = [stdlibURL, sitePackagesURL].filter { fileManager.fileExists(atPath: $0.path) }

		return TTMPythonBundledRuntime(
			rootURL: rootURL,
			libraryURL: libraryURL,
			moduleSearchPaths: moduleSearchPaths,
			pythonVersion: pythonVersion
		)
	}

	private static func parseVersion(fromLibraryName libraryName: String) -> String? {
		let prefix = "libpython"
		let suffix = ".dylib"
		guard libraryName.hasPrefix(prefix), libraryName.hasSuffix(suffix) else {
			return nil
		}
		let start = libraryName.index(libraryName.startIndex, offsetBy: prefix.count)
		let end = libraryName.index(libraryName.endIndex, offsetBy: -suffix.count)
		let version = String(libraryName[start..<end])
		return version.isEmpty ? nil : version
	}
}
