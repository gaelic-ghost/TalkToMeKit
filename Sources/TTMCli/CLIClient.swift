import ArgumentParser
import Foundation

protocol HTTPTransport {
	func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
	let session: URLSession

	func data(for request: URLRequest) async throws -> (Data, URLResponse) {
		try await session.data(for: request)
	}
}

struct GlobalOptions: ParsableArguments {
	@Option(name: .customLong("base-url"), help: "Base URL of the TalkToMe server.")
	var baseURL: String = "http://127.0.0.1:8080"

	@Option(name: .long, help: "Request timeout in seconds.")
	var timeout: Double = 30

	@Flag(help: "Enable verbose request/response logging.")
	var verbose: Bool = false

	func makeClient() throws -> TTMClient {
		guard let url = URL(string: baseURL) else {
			throw CLIError.invalidBaseURL(baseURL)
		}
		return TTMClient(baseURL: url, timeout: timeout, verbose: verbose)
	}
}

struct TTMClient {
	private let baseURL: URL
	private let timeout: Double
	private let verbose: Bool
	private let transport: any HTTPTransport

	init(
		baseURL: URL,
		timeout: Double,
		verbose: Bool,
		session: URLSession = .shared
	) {
		self.init(
			baseURL: baseURL,
			timeout: timeout,
			verbose: verbose,
			transport: URLSessionHTTPTransport(session: session)
		)
	}

	init(baseURL: URL, timeout: Double, verbose: Bool, transport: any HTTPTransport) {
		self.baseURL = baseURL
		self.timeout = timeout
		self.verbose = verbose
		self.transport = transport
	}

	func health() async throws -> EndpointResponse {
		try await requestJSON(path: "/health", method: "GET")
	}

	func version() async throws -> EndpointResponse {
		try await requestJSON(path: "/version", method: "GET")
	}

	func adapters() async throws -> EndpointResponse {
		try await requestJSON(path: "/adapters", method: "GET")
	}

	func adapterStatus(adapterID: String) async throws -> EndpointResponse {
		try await requestJSON(path: "/adapters/\(adapterID)/status", method: "GET")
	}

	func status() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/status", method: "GET")
	}

	func inventory() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/inventory", method: "GET")
	}

	func unload() async throws -> EndpointResponse {
		try await requestJSON(path: "/model/unload", method: "POST")
	}

	func customVoiceSpeakers(modelID: String?) async throws -> EndpointResponse {
		var path = "/custom-voice/speakers"
		if let modelID, !modelID.isEmpty {
			let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelID
			path += "?model_id=\(encoded)"
		}
		return try await requestJSON(path: path, method: "GET")
	}

	func load(request: ModelLoadRequest) async throws -> EndpointResponse {
		let payload = try JSONEncoder().encode(request)
		let (response, data) = try await send(path: "/model/load", method: "POST", contentType: "application/json", body: payload)
		guard response.statusCode == 200 || response.statusCode == 202 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		return EndpointResponse(statusCode: response.statusCode, body: decodeBody(data))
	}

	func synthesize(path: String, payload: Data) async throws -> SynthesizeResult {
		let (response, data) = try await send(path: path, method: "POST", contentType: "application/json", body: payload)
		guard response.statusCode == 200 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		let mimeType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
		guard mimeType.lowercased().contains("audio/wav") else {
			throw CLIError.invalidResponse("Expected audio/wav content type, got '\(mimeType)'.")
		}
		let sampleRate = response.value(forHTTPHeaderField: "X-Sample-Rate").flatMap(Int.init)
		return .init(audioData: data, sampleRate: sampleRate)
	}

	private func requestJSON(path: String, method: String) async throws -> EndpointResponse {
		let (response, data) = try await send(path: path, method: method)
		guard response.statusCode == 200 else {
			throw CLIError.unexpectedStatus(response.statusCode, decodeBody(data))
		}
		return .init(statusCode: response.statusCode, body: decodeBody(data))
	}

	private func send(path: String, method: String, contentType: String? = nil, body: Data? = nil) async throws -> (HTTPURLResponse, Data) {
		guard let url = URL(string: path, relativeTo: baseURL) else {
			throw CLIError.invalidResponse("Failed to build URL from path \(path).")
		}

		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		request.httpBody = body
		if let contentType {
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		}

		if verbose {
			writeToStderr("-> \(method) \(url.absoluteString)\n")
		}

		do {
			let (data, response) = try await transport.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse else {
				throw CLIError.invalidResponse("Non-HTTP response.")
			}
			if verbose {
				writeToStderr("<- \(httpResponse.statusCode) \(url.absoluteString) (\(data.count) bytes)\n")
			}
			return (httpResponse, data)
		} catch {
			throw CLIError.requestFailed(error.localizedDescription)
		}
	}

	private func decodeBody(_ data: Data) -> String {
		String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	}

	private func writeToStderr(_ message: String) {
		guard let data = message.data(using: .utf8) else { return }
		FileHandle.standardError.write(data)
	}
}
