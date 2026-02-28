import Foundation
import OpenAPIRuntime
import TTMOpenAPI
import TTMService

struct TTMServerEnvironment: Sendable, Equatable {
	let synthesisTimeoutSeconds: Int
	let deviceMap: String?
	let torchDtype: String?
	let allowFallback: Bool?

	static func fromProcessInfo(_ processInfo: ProcessInfo = .processInfo) -> Self {
		fromEnvironment(processInfo.environment)
	}

	static func fromEnvironment(_ env: [String: String]) -> Self {
		let timeout = env["TTM_QWEN_SYNTH_TIMEOUT_SECONDS"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 120
		let allowFallback = env["TTM_QWEN_ALLOW_FALLBACK"].flatMap { raw -> Bool? in
			switch raw.lowercased() {
			case "1", "true", "yes":
				return true
			case "0", "false", "no":
				return false
			default:
				return nil
			}
		}
		return .init(
			synthesisTimeoutSeconds: timeout,
			deviceMap: env["TTM_QWEN_DEVICE_MAP"],
			torchDtype: env["TTM_QWEN_TORCH_DTYPE"],
			allowFallback: allowFallback
		)
	}
}

extension TTMApi {
	func modelLoadBody(from body: TTMOpenAPI.Operations.ModelLoadModelLoadPost.Input.Body) -> Components.Schemas.ModelLoadRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	func voiceDesignBody(from body: TTMOpenAPI.Operations.SynthesizeVoiceDesignSynthesizeVoiceDesignPost.Input.Body) -> Components.Schemas.SynthesizeVoiceDesignRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	func customVoiceBody(from body: TTMOpenAPI.Operations.SynthesizeCustomVoiceSynthesizeCustomVoicePost.Input.Body) -> Components.Schemas.SynthesizeCustomVoiceRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	func voiceCloneBody(from body: TTMOpenAPI.Operations.SynthesizeVoiceCloneSynthesizeVoiceClonePost.Input.Body) -> Components.Schemas.SynthesizeVoiceCloneRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	func unloadedModelStatusResponse(
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

	func modelStatusResponse(
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

	func isSupportedAudioFormat(_ format: String?) -> Bool {
		guard let format else {
			return true
		}
		let normalized = format.lowercased()
		return normalized == "wav" || normalized == "audio/wav"
	}

	func currentStatus() async -> TTMPythonBridgeStatus {
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

	func statusContext(
		from status: TTMPythonBridgeStatus,
		fallbackRequested: QwenModelSelection? = nil
	) -> (active: QwenModelSelection, requested: QwenModelSelection, strictLoad: Bool, fallbackApplied: Bool) {
		let active = status.activeModelID.map { .init(mode: status.activeMode ?? $0.mode, modelID: $0) } ?? QwenModelSelection.defaultVoiceDesign
		let requested = status.requestedModelID.map { .init(mode: status.requestedMode ?? $0.mode, modelID: $0) } ?? fallbackRequested ?? active
		return (active, requested, status.strictLoad, status.fallbackApplied)
	}

	func qwenStatusDetail(status: TTMPythonBridgeStatus) -> String {
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

	func modelModeSchema(from mode: QwenSynthesisMode) -> Components.Schemas.ModelMode {
		switch mode {
		case .voiceDesign:
			return .voiceDesign
		case .customVoice:
			return .customVoice
		case .voiceClone:
			return .voiceClone
		}
	}

	func modelIDSchema(from modelID: QwenModelIdentifier) -> Components.Schemas.ModelId {
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

	func synthesisMode(from mode: Components.Schemas.ModelMode) -> QwenSynthesisMode? {
		switch mode {
		case .voiceDesign:
			return .voiceDesign
		case .customVoice:
			return .customVoice
		case .voiceClone:
			return .voiceClone
		}
	}

	func qwenModelIdentifier(from modelID: Components.Schemas.ModelId) -> QwenModelIdentifier? {
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

	func synthesizeWithTimeout(
		request: QwenSynthesisRequest,
		qwenService: any TTMQwenServing
	) async throws -> Data {
		let timeoutCoordinator = SynthesisTimeoutCoordinator()
		let timeoutSeconds = environment.synthesisTimeoutSeconds
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
				try? await Task.sleep(for: .seconds(timeoutSeconds))
				synthTask.cancel()
				await timeoutCoordinator.resumeIfNeeded(continuation: continuation, result: .failure(SynthesisTimeoutError.timedOut))
			}
		}
	}
}

enum SynthesisTimeoutError: Error {
	case timedOut
}

actor SynthesisTimeoutCoordinator {
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
