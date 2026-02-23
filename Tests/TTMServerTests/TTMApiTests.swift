import Foundation
import OpenAPIRuntime
import Testing
@testable import TTMServer
import TTMOpenAPI
import TTMPythonBridge
import TTMService

private struct FakeQwenError: Error, Equatable {}

private actor FakeQwenService: TTMQwenServing {
	var ready = true
	var statusValue: TTMPythonBridgeStatus
	var loadResult = true
	var loadError: Error?
	var unloadResult = true
	var unloadError: Error?
	var synthData = Data("RIFF".utf8)
	var synthError: Error?
	var speakers: [String] = ["ryan", "serena"]
	var speakersError: Error?
	var inventoryItems: [TTMModelInventoryItem] = []
	var lastLoadSelection: QwenModelSelection?
	var lastStrictLoad: Bool?
	var lastSynthesisRequest: QwenSynthesisRequest?

	init(statusValue: TTMPythonBridgeStatus) {
		self.statusValue = statusValue
	}

	func synthesize(_ request: QwenSynthesisRequest) async throws -> Data {
		lastSynthesisRequest = request
		if let synthError {
			throw synthError
		}
		return synthData
	}

	func isReady() async -> Bool {
		ready
	}

	func status() async -> TTMPythonBridgeStatus {
		statusValue
	}

	func loadModel(selection: QwenModelSelection, strict: Bool) async throws -> Bool {
		lastLoadSelection = selection
		lastStrictLoad = strict
		if let loadError {
			throw loadError
		}
		return loadResult
	}

	func unloadModel() async throws -> Bool {
		if let unloadError {
			throw unloadError
		}
		return unloadResult
	}

	func supportedCustomVoiceSpeakers(modelID: QwenModelIdentifier) async throws -> [String] {
		_ = modelID
		if let speakersError {
			throw speakersError
		}
		return speakers
	}

	func modelInventory() async -> [TTMModelInventoryItem] {
		inventoryItems
	}

	func capturedSynthesisRequest() -> QwenSynthesisRequest? {
		lastSynthesisRequest
	}

	func configureReady(_ value: Bool) {
		ready = value
	}

	func configureLoad(result: Bool, error: Error? = nil) {
		loadResult = result
		loadError = error
	}

	func configureUnload(result: Bool, error: Error? = nil) {
		unloadResult = result
		unloadError = error
	}

	func configureSynthesis(data: Data, error: Error? = nil) {
		synthData = data
		synthError = error
	}

	func configureSpeakers(_ values: [String], error: Error? = nil) {
		speakers = values
		speakersError = error
	}

	func configureInventory(_ values: [TTMModelInventoryItem]) {
		inventoryItems = values
	}
}

@Suite("TTM API endpoints", .serialized)
struct TTMApiTests {
	@Test("GET /health returns service health payload")
	func health() async throws {
		let api = TTMApi()
		let output = try await api.healthHealthGet(.init())
		let body = try output.ok.body.json
		#expect(body.status == "ok")
		#expect(body.service == "TalkToMeKit")
	}

	@Test("GET /version returns API version metadata")
	func version() async throws {
		let api = TTMApi()
		let output = try await api.versionVersionGet(.init())
		let body = try output.ok.body.json
		#expect(body.apiVersion == "0.5.0")
		#expect(body.openapiVersion == "3.1.0")
	}

	@Test("GET /adapters returns qwen adapter")
	func adapters() async throws {
		let api = TTMApi()
		let output = try await api.adaptersAdaptersGet(.init())
		let body = try output.ok.body.json
		#expect(body.adapters.count == 1)
		#expect(body.adapters[0].id == "qwen3-tts")
	}

	@Test("GET /adapters/{id}/status reports disabled service state when no runtime is configured")
	func adapterStatusDisabled() async throws {
		let api = TTMApi()
		let output = try await api.adapterStatusAdaptersAdapterIdStatusGet(.init(path: .init(adapterId: "qwen3-tts")))
		let body = try output.ok.body.json
		#expect(body.qwenTtsAvailable == false)
		#expect(body.loaded == false)
		#expect(body.detail.contains("disabled"))
	}

	@Test("GET /model/status uses active and requested state from runtime status")
	func modelStatusReady() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice1_7B,
			requestedMode: .customVoice,
			requestedModelID: .customVoice1_7B,
			strictLoad: true,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let output = try await api.modelStatusModelStatusGet(.init())
		let body = try output.ok.body.json
		#expect(body.mode == .customVoice)
		#expect(body.modelId == .qwenQwen3TTS12Hz1_7BCustomVoice)
		#expect(body.requestedModelId == .qwenQwen3TTS12Hz1_7BCustomVoice)
		#expect(body.strictLoad == true)
		#expect(body.fallbackApplied == false)
		#expect(body.ready == true)
	}

	@Test("GET /model/inventory returns disabled defaults without service")
	func modelInventoryDisabled() async throws {
		let api = TTMApi()
		let output = try await api.modelInventoryModelInventoryGet(.init())
		let body = try output.ok.body.json
		#expect(body.models.count == QwenModelIdentifier.allCases.count)
		#expect(body.models.allSatisfy { $0.available == false })
	}

	@Test("GET /model/inventory returns fake service inventory entries")
	func modelInventoryEnabled() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: false,
			activeMode: nil,
			activeModelID: nil,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: false,
			lastError: nil
		))
		await fake.configureInventory([
			.init(mode: .voiceDesign, modelID: .voiceDesign1_7B, available: true, localPath: "/tmp/vd"),
		])
		let api = TTMApi(qwenService: fake)
		let output = try await api.modelInventoryModelInventoryGet(.init())
		let body = try output.ok.body.json
		#expect(body.models.count == 1)
		#expect(body.models[0].modelId == .qwenQwen3TTS12Hz1_7BVoiceDesign)
		#expect(body.models[0].available == true)
	}

	@Test("POST /model/load validates incompatible mode and model")
	func modelLoadBadRequestForIncompatibleSelection() async throws {
		let api = TTMApi()
		let request = Components.Schemas.ModelLoadRequest(
			mode: .voiceDesign,
			modelId: .qwenQwen3TTS12Hz0_6BCustomVoice
		)
		let output = try await api.modelLoadModelLoadPost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /model/load validates incompatible voice_clone mode and model")
	func modelLoadBadRequestForIncompatibleVoiceCloneSelection() async throws {
		let api = TTMApi()
		let request = Components.Schemas.ModelLoadRequest(
			mode: .voiceClone,
			modelId: .qwenQwen3TTS12Hz1_7BCustomVoice
		)
		let output = try await api.modelLoadModelLoadPost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /model/load returns accepted when service is disabled")
	func modelLoadAcceptedWhenServiceDisabled() async throws {
		let api = TTMApi()
		let request = Components.Schemas.ModelLoadRequest(
			mode: .customVoice,
			modelId: .qwenQwen3TTS12Hz1_7BCustomVoice,
			strictLoad: true
		)
		let output = try await api.modelLoadModelLoadPost(.init(body: .json(request)))
		let body = try output.accepted.body.json
		#expect(body.loaded == false)
		#expect(body.strictLoad == true)
	}

	@Test("POST /model/load returns ok after successful load")
	func modelLoadSuccess() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice0_6B,
			requestedMode: .customVoice,
			requestedModelID: .customVoice0_6B,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureLoad(result: true)
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.ModelLoadRequest(mode: .customVoice, strictLoad: false)
		let output = try await api.modelLoadModelLoadPost(.init(body: .json(request)))
		let body = try output.ok.body.json
		#expect(body.loaded == true)
		#expect(body.modelId == .qwenQwen3TTS12Hz0_6BCustomVoice)
	}

	@Test("POST /model/load returns accepted when load throws")
	func modelLoadFailureFallsBackToAccepted() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: false,
			activeMode: .voiceDesign,
			activeModelID: .voiceDesign1_7B,
			requestedMode: .customVoice,
			requestedModelID: .customVoice1_7B,
			strictLoad: true,
			fallbackApplied: true,
			ready: false,
			lastError: "load failed"
		))
		await fake.configureLoad(result: false, error: FakeQwenError())
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.ModelLoadRequest(
			mode: .customVoice,
			modelId: .qwenQwen3TTS12Hz1_7BCustomVoice,
			strictLoad: true
		)
		let output = try await api.modelLoadModelLoadPost(.init(body: .json(request)))
		let body = try output.accepted.body.json
		#expect(body.loaded == false)
		#expect(body.fallbackApplied == true)
	}

	@Test("POST /model/unload remains idempotent even when unload throws")
	func modelUnloadIdempotent() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: false,
			activeMode: .voiceDesign,
			activeModelID: .voiceDesign1_7B,
			requestedMode: .voiceDesign,
			requestedModelID: .voiceDesign1_7B,
			strictLoad: false,
			fallbackApplied: false,
			ready: false,
			lastError: nil
		))
		await fake.configureUnload(result: false, error: FakeQwenError())
		let api = TTMApi(qwenService: fake)
		let output = try await api.modelUnloadModelUnloadPost(.init())
		let body = try output.ok.body.json
		#expect(body.loaded == false)
	}

	@Test("GET /custom-voice/speakers validates mode-specific model IDs")
	func customVoiceSpeakersBadRequestForVoiceDesignModel() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let output = try await api.customVoiceSpeakersCustomVoiceSpeakersGet(
			.init(query: .init(modelId: .qwenQwen3TTS12Hz1_7BVoiceDesign))
		)
		_ = try output.badRequest
	}

	@Test("GET /custom-voice/speakers returns service unavailable without runtime")
	func customVoiceSpeakersUnavailableWithoutService() async throws {
		let api = TTMApi()
		let output = try await api.customVoiceSpeakersCustomVoiceSpeakersGet(.init())
		_ = try output.serviceUnavailable
	}

	@Test("GET /custom-voice/speakers returns available speaker list")
	func customVoiceSpeakersSuccess() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureSpeakers(["ryan", "serena", "emma"])
		let api = TTMApi(qwenService: fake)
		let output = try await api.customVoiceSpeakersCustomVoiceSpeakersGet(.init())
		let body = try output.ok.body.json
		#expect(body.speakers.count == 3)
	}

	@Test("POST /synthesize/voice-design enforces wav format")
	func synthesizeVoiceDesignBadFormat() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceDesign,
			activeModelID: .voiceDesign1_7B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceDesignRequest(
			text: "hello",
			instruct: "warm narrator",
			language: "English",
			format: "mp3"
		)
		let output = try await api.synthesizeVoiceDesignSynthesizeVoiceDesignPost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /synthesize/voice-design returns success for ready runtime")
	func synthesizeVoiceDesignSuccess() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceDesign,
			activeModelID: .voiceDesign1_7B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureReady(true)
		await fake.configureSynthesis(data: Data("RIFF-test".utf8))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceDesignRequest(
			text: "hello",
			instruct: "warm narrator",
			language: "English"
		)
		let output = try await api.synthesizeVoiceDesignSynthesizeVoiceDesignPost(.init(body: .json(request)))
		_ = try output.ok.body.audioWav
	}

	@Test("POST /synthesize/voice-design returns internal server error on synthesis exception")
	func synthesizeVoiceDesignInternalError() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceDesign,
			activeModelID: .voiceDesign1_7B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureSynthesis(data: Data(), error: FakeQwenError())
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceDesignRequest(
			text: "hello",
			instruct: "warm narrator",
			language: "English"
		)
		let output = try await api.synthesizeVoiceDesignSynthesizeVoiceDesignPost(.init(body: .json(request)))
		_ = try output.internalServerError
	}

	@Test("POST /synthesize/custom-voice validates mode/model compatibility")
	func synthesizeCustomVoiceBadModel() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeCustomVoiceRequest(
			text: "hello",
			speaker: "ryan",
			language: "English",
			modelId: .qwenQwen3TTS12Hz1_7BVoiceDesign
		)
		let output = try await api.synthesizeCustomVoiceSynthesizeCustomVoicePost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /synthesize/custom-voice returns service unavailable when runtime is not ready")
	func synthesizeCustomVoiceUnavailableWhenNotReady() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: false,
			activeMode: .customVoice,
			activeModelID: .customVoice0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: false,
			lastError: nil
		))
		await fake.configureReady(false)
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeCustomVoiceRequest(
			text: "hello",
			speaker: "ryan",
			language: "English"
		)
		let output = try await api.synthesizeCustomVoiceSynthesizeCustomVoicePost(.init(body: .json(request)))
		_ = try output.serviceUnavailable
	}

	@Test("POST /synthesize/custom-voice returns wav audio for valid requests")
	func synthesizeCustomVoiceSuccess() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .customVoice,
			activeModelID: .customVoice1_7B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureSynthesis(data: Data("RIFF-cv".utf8))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeCustomVoiceRequest(
			text: "hello",
			speaker: "ryan",
			instruct: "cheerful and energetic",
			language: "English",
			modelId: .qwenQwen3TTS12Hz1_7BCustomVoice
		)
		let output = try await api.synthesizeCustomVoiceSynthesizeCustomVoicePost(.init(body: .json(request)))
		_ = try output.ok.body.audioWav
		let captured = await fake.capturedSynthesisRequest()
		#expect(captured?.instruct == "cheerful and energetic")
	}

	@Test("POST /synthesize/voice-clone validates base64 input")
	func synthesizeVoiceCloneBadBase64() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceClone,
			activeModelID: .voiceClone0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceCloneRequest(
			text: "hello",
			referenceAudioB64: "not-base64",
			language: "English"
		)
		let output = try await api.synthesizeVoiceCloneSynthesizeVoiceClonePost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /synthesize/voice-clone validates mode/model compatibility")
	func synthesizeVoiceCloneBadModel() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceClone,
			activeModelID: .voiceClone0_6B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceCloneRequest(
			text: "hello",
			referenceAudioB64: Data("ref".utf8).base64EncodedString(),
			language: "English",
			modelId: .qwenQwen3TTS12Hz1_7BCustomVoice
		)
		let output = try await api.synthesizeVoiceCloneSynthesizeVoiceClonePost(.init(body: .json(request)))
		_ = try output.badRequest
	}

	@Test("POST /synthesize/voice-clone returns wav audio for valid requests")
	func synthesizeVoiceCloneSuccess() async throws {
		let fake = FakeQwenService(statusValue: .init(
			runtimeInitialized: true,
			moduleLoaded: true,
			modelLoaded: true,
			activeMode: .voiceClone,
			activeModelID: .voiceClone1_7B,
			requestedMode: nil,
			requestedModelID: nil,
			strictLoad: false,
			fallbackApplied: false,
			ready: true,
			lastError: nil
		))
		await fake.configureSynthesis(data: Data("RIFF-clone".utf8))
		let api = TTMApi(qwenService: fake)
		let request = Components.Schemas.SynthesizeVoiceCloneRequest(
			text: "hello",
			referenceAudioB64: Data("ref".utf8).base64EncodedString(),
			language: "English",
			modelId: .qwenQwen3TTS12Hz1_7BBase
		)
		let output = try await api.synthesizeVoiceCloneSynthesizeVoiceClonePost(.init(body: .json(request)))
		_ = try output.ok.body.audioWav
		let captured = await fake.capturedSynthesisRequest()
		#expect(captured?.mode == .voiceClone)
		#expect(captured?.modelID == .voiceClone1_7B)
		#expect(captured?.referenceAudio == Data("ref".utf8))
	}
}
