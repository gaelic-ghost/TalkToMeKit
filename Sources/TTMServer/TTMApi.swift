import Foundation
import Logging
import OpenAPIRuntime
import TTMOpenAPI
import TTMService

struct TTMApi: APIProtocol {
	private let qwenService: (any TTMQwenServing)?
	private let logger: Logger

	init(qwenService: (any TTMQwenServing)? = nil, logger: Logger = .init(label: "TalkToMeKit.TTMApi")) {
		self.qwenService = qwenService
		self.logger = logger
	}

	func healthHealthGet(_ input: TTMOpenAPI.Operations.HealthHealthGet.Input) async throws -> TTMOpenAPI.Operations.HealthHealthGet.Output {
		_ = input
		let payload = Components.Schemas.HealthResponse(status: "ok", service: "TalkToMeKit")
		return .ok(.init(body: .json(payload)))
	}

	func versionVersionGet(_ input: TTMOpenAPI.Operations.VersionVersionGet.Input) async throws -> TTMOpenAPI.Operations.VersionVersionGet.Output {
		_ = input
		let payload = Components.Schemas.VersionResponse(
			service: "TalkToMeKit",
			apiVersion: "0.5.0",
			openapiVersion: "3.1.0"
		)
		return .ok(.init(body: .json(payload)))
	}

	func adaptersAdaptersGet(_ input: TTMOpenAPI.Operations.AdaptersAdaptersGet.Input) async throws -> TTMOpenAPI.Operations.AdaptersAdaptersGet.Output {
		_ = input
		let adapters = [
			Components.Schemas.AdapterInfo(
				id: "qwen3-tts",
				name: "Qwen3-TTS",
				statusPath: "/adapters/qwen3-tts/status"
			),
		]
		return .ok(.init(body: .json(.init(adapters: adapters))))
	}

	func adapterStatusAdaptersAdapterIdStatusGet(_ input: TTMOpenAPI.Operations.AdapterStatusAdaptersAdapterIdStatusGet.Input) async throws -> TTMOpenAPI.Operations.AdapterStatusAdaptersAdapterIdStatusGet.Output {
		let status = await currentStatus()
		let context = statusContext(from: status)
		let payload = Components.Schemas.AdapterStatusResponse(
			adapterId: input.path.adapterId,
			mode: modelModeSchema(from: context.active.mode),
			modelId: modelIDSchema(from: context.active.modelID),
			requestedMode: modelModeSchema(from: context.requested.mode),
			requestedModelId: modelIDSchema(from: context.requested.modelID),
			loaded: status.modelLoaded,
			loading: false,
			qwenTtsAvailable: qwenService != nil,
			ready: status.ready,
			strictLoad: context.strictLoad,
			fallbackApplied: context.fallbackApplied,
			detail: qwenStatusDetail(status: status)
		)
		return .ok(.init(body: .json(payload)))
	}

	func modelStatusModelStatusGet(_ input: TTMOpenAPI.Operations.ModelStatusModelStatusGet.Input) async throws -> TTMOpenAPI.Operations.ModelStatusModelStatusGet.Output {
		_ = input
		let status = await currentStatus()
		let context = statusContext(from: status)
		let payload = modelStatusResponse(
			active: context.active,
			requested: context.requested,
			strictLoad: context.strictLoad,
			fallbackApplied: context.fallbackApplied,
			modelLoaded: status.modelLoaded,
			ready: status.ready,
			detail: qwenStatusDetail(status: status)
		)
		return .ok(.init(body: .json(payload)))
	}

	func modelInventoryModelInventoryGet(_ input: TTMOpenAPI.Operations.ModelInventoryModelInventoryGet.Input) async throws -> TTMOpenAPI.Operations.ModelInventoryModelInventoryGet.Output {
		_ = input
		let models: [Components.Schemas.ModelInventoryEntry]
		if let qwenService {
			let inventory = await qwenService.modelInventory()
			models = inventory.map {
				.init(
					mode: modelModeSchema(from: $0.mode),
					modelId: modelIDSchema(from: $0.modelID),
					available: $0.available,
					localPath: $0.localPath
				)
			}
		} else {
			models = QwenModelIdentifier.allCases.map {
				.init(
					mode: modelModeSchema(from: $0.mode),
					modelId: modelIDSchema(from: $0),
					available: false,
					localPath: ""
				)
			}
		}
		return .ok(.init(body: .json(.init(models: models))))
	}

	func modelLoadModelLoadPost(_ input: TTMOpenAPI.Operations.ModelLoadModelLoadPost.Input) async throws -> TTMOpenAPI.Operations.ModelLoadModelLoadPost.Output {
		let request = modelLoadBody(from: input.body)
		guard let mode = synthesisMode(from: request.mode) else {
			return .badRequest
		}
		let requestedModel = request.modelId.flatMap(qwenModelIdentifier(from:))
		if request.modelId != nil, requestedModel == nil {
			return .badRequest
		}
		let strictLoad = request.strictLoad ?? false
		let selection = QwenModelSelection(mode: mode, modelID: requestedModel)
		guard selection.modelID.mode == selection.mode else {
			return .badRequest
		}

		guard let qwenService else {
			let payload = unloadedModelStatusResponse(
				active: selection,
				requested: selection,
				strictLoad: strictLoad,
				fallbackApplied: false,
				detail: "Qwen3-TTS service is disabled; start server with --python-runtime-root"
			)
			return .accepted(.init(body: .json(payload)))
		}

		do {
			let loaded = try await qwenService.loadModel(selection: selection, strict: strictLoad)
			let status = await qwenService.status()
			let context = statusContext(from: status)
			let payload = modelStatusResponse(
				active: context.active,
				requested: context.requested,
				strictLoad: context.strictLoad,
				fallbackApplied: context.fallbackApplied,
				modelLoaded: loaded,
				ready: status.ready,
				detail: qwenStatusDetail(status: status)
			)
			return loaded ? .ok(.init(body: .json(payload))) : .accepted(.init(body: .json(payload)))
		} catch {
			let status = await currentStatus()
			let context = statusContext(from: status, fallbackRequested: selection)
			let payload = unloadedModelStatusResponse(
				active: context.active,
				requested: context.requested,
				strictLoad: context.strictLoad,
				fallbackApplied: context.fallbackApplied,
				detail: qwenStatusDetail(status: status)
			)
			return .accepted(.init(body: .json(payload)))
		}
	}

	func modelUnloadModelUnloadPost(_ input: TTMOpenAPI.Operations.ModelUnloadModelUnloadPost.Input) async throws -> TTMOpenAPI.Operations.ModelUnloadModelUnloadPost.Output {
		_ = input
		guard let qwenService else {
			let selection = QwenModelSelection.defaultVoiceDesign
			let payload = unloadedModelStatusResponse(
				active: selection,
				requested: selection,
				strictLoad: false,
				fallbackApplied: false,
				detail: "Qwen3-TTS service is disabled; start server with --python-runtime-root"
			)
			return .ok(.init(body: .json(payload)))
		}

		do {
			_ = try await qwenService.unloadModel()
		} catch {
			// Keep endpoint idempotent; report unloaded status either way.
		}
		let status = await currentStatus()
		let context = statusContext(from: status)
		let payload = unloadedModelStatusResponse(
			active: context.active,
			requested: context.requested,
			strictLoad: context.strictLoad,
			fallbackApplied: context.fallbackApplied,
			detail: qwenStatusDetail(status: status)
		)
		return .ok(.init(body: .json(payload)))
	}

	func customVoiceSpeakersCustomVoiceSpeakersGet(_ input: TTMOpenAPI.Operations.CustomVoiceSpeakersCustomVoiceSpeakersGet.Input) async throws -> TTMOpenAPI.Operations.CustomVoiceSpeakersCustomVoiceSpeakersGet.Output {
		let requestedModel = input.query.modelId.flatMap(qwenModelIdentifier(from:)) ?? .customVoice0_6B
		guard requestedModel.mode == .customVoice else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}

		do {
			let speakers = try await qwenService.supportedCustomVoiceSpeakers(modelID: requestedModel)
			let payload = Components.Schemas.CustomVoiceSpeakersResponse(
				modelId: modelIDSchema(from: requestedModel),
				speakers: speakers
			)
			return .ok(.init(body: .json(payload)))
		} catch {
			logger.error("Failed to list custom voice speakers", metadata: ["error": "\(String(describing: error))"])
			return .serviceUnavailable
		}
	}

	func synthesizeVoiceDesignSynthesizeVoiceDesignPost(_ input: TTMOpenAPI.Operations.SynthesizeVoiceDesignSynthesizeVoiceDesignPost.Input) async throws -> TTMOpenAPI.Operations.SynthesizeVoiceDesignSynthesizeVoiceDesignPost.Output {
		let request = voiceDesignBody(from: input.body)
		guard isSupportedAudioFormat(request.format) else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}
		guard await qwenService.isReady() else {
			return .serviceUnavailable
		}

		let modelID = request.modelId.flatMap(qwenModelIdentifier(from:)) ?? .voiceDesign1_7B
		guard modelID.mode == .voiceDesign else {
			return .badRequest
		}
		let qwenRequest = QwenSynthesisRequest.voiceDesign(
			text: request.text,
			instruct: request.instruct,
			language: request.language,
			modelID: modelID
		)

		do {
			let wavBytes = try await synthesizeWithTimeout(request: qwenRequest, qwenService: qwenService)
			let body = HTTPBody(wavBytes)
			return .ok(.init(body: .audioWav(body)))
		} catch is SynthesisTimeoutError {
			return .serviceUnavailable
		} catch {
			return .internalServerError
		}
	}

	func synthesizeCustomVoiceSynthesizeCustomVoicePost(_ input: TTMOpenAPI.Operations.SynthesizeCustomVoiceSynthesizeCustomVoicePost.Input) async throws -> TTMOpenAPI.Operations.SynthesizeCustomVoiceSynthesizeCustomVoicePost.Output {
		let request = customVoiceBody(from: input.body)
		guard isSupportedAudioFormat(request.format) else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}
		guard await qwenService.isReady() else {
			return .serviceUnavailable
		}

		let modelID = request.modelId.flatMap(qwenModelIdentifier(from:)) ?? .customVoice0_6B
		guard modelID.mode == .customVoice else {
			return .badRequest
		}
		let qwenRequest = QwenSynthesisRequest.customVoice(
			text: request.text,
			speaker: request.speaker,
			instruct: request.instruct,
			language: request.language,
			modelID: modelID
		)

		do {
			let wavBytes = try await synthesizeWithTimeout(request: qwenRequest, qwenService: qwenService)
			let body = HTTPBody(wavBytes)
			return .ok(.init(body: .audioWav(body)))
		} catch is SynthesisTimeoutError {
			return .serviceUnavailable
		} catch {
			return .internalServerError
		}
	}

	func synthesizeVoiceCloneSynthesizeVoiceClonePost(_ input: TTMOpenAPI.Operations.SynthesizeVoiceCloneSynthesizeVoiceClonePost.Input) async throws -> TTMOpenAPI.Operations.SynthesizeVoiceCloneSynthesizeVoiceClonePost.Output {
		let request = voiceCloneBody(from: input.body)
		guard isSupportedAudioFormat(request.format) else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}
		guard await qwenService.isReady() else {
			return .serviceUnavailable
		}
		guard let referenceAudio = Data(base64Encoded: request.referenceAudioB64) else {
			return .badRequest
		}

		let modelID = request.modelId.flatMap(qwenModelIdentifier(from:)) ?? .voiceClone0_6B
		guard modelID.mode == .voiceClone else {
			return .badRequest
		}
		let qwenRequest = QwenSynthesisRequest.voiceClone(
			text: request.text,
			referenceAudio: referenceAudio,
			language: request.language,
			modelID: modelID
		)

		do {
			let wavBytes = try await synthesizeWithTimeout(request: qwenRequest, qwenService: qwenService)
			let body = HTTPBody(wavBytes)
			return .ok(.init(body: .audioWav(body)))
		} catch is SynthesisTimeoutError {
			return .serviceUnavailable
		} catch {
			return .internalServerError
		}
	}

	private func modelLoadBody(from body: TTMOpenAPI.Operations.ModelLoadModelLoadPost.Input.Body) -> Components.Schemas.ModelLoadRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func voiceDesignBody(from body: TTMOpenAPI.Operations.SynthesizeVoiceDesignSynthesizeVoiceDesignPost.Input.Body) -> Components.Schemas.SynthesizeVoiceDesignRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func customVoiceBody(from body: TTMOpenAPI.Operations.SynthesizeCustomVoiceSynthesizeCustomVoicePost.Input.Body) -> Components.Schemas.SynthesizeCustomVoiceRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func voiceCloneBody(from body: TTMOpenAPI.Operations.SynthesizeVoiceCloneSynthesizeVoiceClonePost.Input.Body) -> Components.Schemas.SynthesizeVoiceCloneRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func unloadedModelStatusResponse(
		active: QwenModelSelection,
		requested: QwenModelSelection,
		strictLoad: Bool,
		fallbackApplied: Bool,
		detail: String
	) -> Components.Schemas.ModelStatusResponse {
		modelStatusResponse(
			active: active,
			requested: requested,
			strictLoad: strictLoad,
			fallbackApplied: fallbackApplied,
			modelLoaded: false,
			ready: false,
			detail: detail
		)
	}

	private func modelStatusResponse(
		active: QwenModelSelection,
		requested: QwenModelSelection,
		strictLoad: Bool,
		fallbackApplied: Bool,
		modelLoaded: Bool,
		ready: Bool,
		detail: String
	) -> Components.Schemas.ModelStatusResponse {
		.init(
			mode: modelModeSchema(from: active.mode),
			modelId: modelIDSchema(from: active.modelID),
			requestedMode: modelModeSchema(from: requested.mode),
			requestedModelId: modelIDSchema(from: requested.modelID),
			loaded: modelLoaded,
			loading: false,
			qwenTtsAvailable: qwenService != nil,
			ready: ready,
			strictLoad: strictLoad,
			fallbackApplied: fallbackApplied,
			detail: detail
		)
	}

	private func isSupportedAudioFormat(_ format: String?) -> Bool {
		guard let format else {
			return true
		}
		let normalized = format.lowercased()
		return normalized == "wav" || normalized == "audio/wav"
	}

	private func currentStatus() async -> TTMPythonBridgeStatus {
		guard let qwenService else {
			return .init(
				runtimeInitialized: false,
				moduleLoaded: false,
				modelLoaded: false,
				activeMode: nil,
				activeModelID: nil,
				requestedMode: nil,
				requestedModelID: nil,
				strictLoad: false,
				fallbackApplied: false,
				ready: false,
				lastError: nil
			)
		}
		return await qwenService.status()
	}

	private func statusContext(
		from status: TTMPythonBridgeStatus,
		fallbackRequested: QwenModelSelection? = nil
	) -> (active: QwenModelSelection, requested: QwenModelSelection, strictLoad: Bool, fallbackApplied: Bool) {
		let active = status.activeModelID.map { .init(mode: status.activeMode ?? $0.mode, modelID: $0) } ?? QwenModelSelection.defaultVoiceDesign
		let requested = status.requestedModelID.map { .init(mode: status.requestedMode ?? $0.mode, modelID: $0) } ?? fallbackRequested ?? active
		return (active, requested, status.strictLoad, status.fallbackApplied)
	}

	private func qwenStatusDetail(status: TTMPythonBridgeStatus) -> String {
		if status.ready {
			return "Qwen3-TTS runtime is ready"
		}
		if qwenService == nil {
			return "Qwen3-TTS service is disabled; start server with --python-runtime-root"
		}
		if let lastError = status.lastError, !lastError.isEmpty {
			return "Qwen3-TTS error: \(lastError)"
		}
		if !status.runtimeInitialized {
			return "Qwen3-TTS runtime is not initialized"
		}
		if !status.moduleLoaded {
			return "Qwen3-TTS module is not loaded"
		}
		if !status.modelLoaded {
			return "Qwen3-TTS service is running; model not loaded"
		}
		return "Qwen3-TTS service is starting or unavailable"
	}

	private func modelModeSchema(from mode: QwenSynthesisMode) -> Components.Schemas.ModelMode {
		switch mode {
		case .voiceDesign:
			return .voiceDesign
		case .customVoice:
			return .customVoice
		case .voiceClone:
			return .voiceClone
		}
	}

	private func modelIDSchema(from modelID: QwenModelIdentifier) -> Components.Schemas.ModelId {
		switch modelID {
		case .voiceDesign1_7B:
			return .qwenQwen3TTS12Hz1_7BVoiceDesign
		case .customVoice0_6B:
			return .qwenQwen3TTS12Hz0_6BCustomVoice
		case .customVoice1_7B:
			return .qwenQwen3TTS12Hz1_7BCustomVoice
		case .voiceClone0_6B:
			return .qwenQwen3TTS12Hz0_6BBase
		case .voiceClone1_7B:
			return .qwenQwen3TTS12Hz1_7BBase
		}
	}

	private func synthesisMode(from mode: Components.Schemas.ModelMode) -> QwenSynthesisMode? {
		switch mode {
		case .voiceDesign:
			return .voiceDesign
		case .customVoice:
			return .customVoice
		case .voiceClone:
			return .voiceClone
		}
	}

	private func qwenModelIdentifier(from modelID: Components.Schemas.ModelId) -> QwenModelIdentifier? {
		switch modelID {
		case .qwenQwen3TTS12Hz1_7BVoiceDesign:
			return .voiceDesign1_7B
		case .qwenQwen3TTS12Hz0_6BCustomVoice:
			return .customVoice0_6B
		case .qwenQwen3TTS12Hz1_7BCustomVoice:
			return .customVoice1_7B
		case .qwenQwen3TTS12Hz0_6BBase:
			return .voiceClone0_6B
		case .qwenQwen3TTS12Hz1_7BBase:
			return .voiceClone1_7B
		}
	}

	private func synthesizeWithTimeout(
		request: QwenSynthesisRequest,
		qwenService: any TTMQwenServing
	) async throws -> Data {
		let timeoutCoordinator = SynthesisTimeoutCoordinator()
		return try await withCheckedThrowingContinuation { continuation in
			let synthTask = Task {
				do {
					let data = try await qwenService.synthesize(request)
					await timeoutCoordinator.resumeIfNeeded(continuation: continuation, result: .success(data))
				} catch {
					await timeoutCoordinator.resumeIfNeeded(continuation: continuation, result: .failure(error))
				}
			}

			Task.detached {
				try? await Task.sleep(for: .seconds(Self.synthesisTimeoutSeconds))
				synthTask.cancel()
				await timeoutCoordinator.resumeIfNeeded(continuation: continuation, result: .failure(SynthesisTimeoutError.timedOut))
			}
		}
	}

	private enum SynthesisTimeoutError: Error {
		case timedOut
	}

	private actor SynthesisTimeoutCoordinator {
		private var isCompleted = false

		func resumeIfNeeded(
			continuation: CheckedContinuation<Data, Error>,
			result: Result<Data, Error>
		) {
			guard !isCompleted else {
				return
			}
			isCompleted = true
			continuation.resume(with: result)
		}
	}

	private static let synthesisTimeoutSeconds: Int = {
		let configured = ProcessInfo.processInfo.environment["TTM_QWEN_SYNTH_TIMEOUT_SECONDS"]
		if let configured, let seconds = Int(configured), seconds > 0 {
			return seconds
		}
		return 120
	}()
}
