import Foundation
import Testing
@testable import TTMCli

private struct StubHTTPTransport: HTTPTransport {
	let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

	func data(for request: URLRequest) async throws -> (Data, URLResponse) {
		try handler(request)
	}
}

struct TTMCliTests {
	@Test("synthesis input rejects both --text and --text-file")
	func synthesisInputRejectsTextAndFile() throws {
		do {
			try SynthesisRequestBuilder.validateInput(
				text: "hello",
				textFile: "/tmp/input.txt",
				mode: .voiceDesign,
				referenceAudio: nil
			)
			Issue.record("Expected bothTextAndFileProvided")
		} catch let error as CLIError {
			switch error {
			case .bothTextAndFileProvided:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test("synthesis input requires text input")
	func synthesisInputRequiresText() throws {
		do {
			try SynthesisRequestBuilder.validateInput(
				text: nil,
				textFile: nil,
				mode: .voiceDesign,
				referenceAudio: nil
			)
			Issue.record("Expected missingTextInput")
		} catch let error as CLIError {
			switch error {
			case .missingTextInput:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test("voice-clone input requires reference audio")
	func voiceCloneRequiresReferenceAudio() throws {
		do {
			try SynthesisRequestBuilder.validateInput(
				text: "hello",
				textFile: nil,
				mode: .voiceClone,
				referenceAudio: nil
			)
			Issue.record("Expected missingReferenceAudio")
		} catch let error as CLIError {
			switch error {
			case .missingReferenceAudio:
				break
			default:
				Issue.record("Unexpected error: \(error)")
			}
		}
	}

	@Test("voice-design request builder emits endpoint and payload")
	func voiceDesignBuilderEmitsRequest() throws {
		let built = try SynthesisRequestBuilder.buildRequest(
			from: .init(
				text: "Hello",
				textFile: nil,
				mode: .voiceDesign,
				speaker: nil,
				instruct: nil,
				language: "English",
				modelID: nil,
				referenceAudio: nil,
				format: .wav
			)
		)
		#expect(built.path == "/synthesize/voice-design")
		let payload = try JSONDecoder().decode(VoiceDesignRequest.self, from: built.payload)
		#expect(payload.text == "Hello")
		#expect(payload.instruct.contains("warm and clear"))
		#expect(payload.format == "wav")
	}

	@Test("voice-clone request builder base64-encodes reference audio")
	func voiceCloneBuilderEncodesReferenceAudio() throws {
		let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ttm-cli-test-\(UUID().uuidString).wav")
		try Data("ref".utf8).write(to: temp)
		defer { try? FileManager.default.removeItem(at: temp) }

		let built = try SynthesisRequestBuilder.buildRequest(
			from: .init(
				text: "Hello",
				textFile: nil,
				mode: .voiceClone,
				speaker: nil,
				instruct: nil,
				language: "English",
				modelID: nil,
				referenceAudio: temp.path,
				format: .wav
			)
		)
		let payload = try JSONDecoder().decode(VoiceCloneRequest.self, from: built.payload)
		#expect(payload.referenceAudioB64 == Data("ref".utf8).base64EncodedString())
	}

	@Test("client maps non-2xx status to unexpectedStatus")
	func clientMapsNon2xxToUnexpectedStatus() async throws {
		let url = URL(string: "http://127.0.0.1:8080/health")!
		let client = TTMClient(
			baseURL: URL(string: "http://127.0.0.1:8080")!,
			timeout: 30,
			verbose: false,
			transport: StubHTTPTransport { _ in
				let body = Data("oops".utf8)
				let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
				return (body, response)
			}
		)

		do {
			_ = try await client.health()
			Issue.record("Expected CLIError.unexpectedStatus")
		} catch let error as CLIError {
			switch error {
			case .unexpectedStatus(let status, let body):
				#expect(status == 503)
				#expect(body == "oops")
			default:
				Issue.record("Unexpected CLIError variant: \(error)")
			}
		}
	}

	@Test("client synthesize rejects non-wav content type")
	func clientSynthesizeRejectsNonWavContentType() async throws {
		let url = URL(string: "http://127.0.0.1:8080/synthesize/voice-design")!
		let client = TTMClient(
			baseURL: URL(string: "http://127.0.0.1:8080")!,
			timeout: 30,
			verbose: false,
			transport: StubHTTPTransport { _ in
				let body = Data("json".utf8)
				let response = HTTPURLResponse(
					url: url,
					statusCode: 200,
					httpVersion: nil,
					headerFields: ["Content-Type": "application/json"]
				)!
				return (body, response)
			}
		)

		do {
			_ = try await client.synthesize(path: "/synthesize/voice-design", payload: Data("{}".utf8))
			Issue.record("Expected CLIError.invalidResponse")
		} catch let error as CLIError {
			switch error {
			case .invalidResponse(let message):
				#expect(message.contains("audio/wav"))
			default:
				Issue.record("Unexpected CLIError variant: \(error)")
			}
		}
	}
}
