import Foundation
import OpenAPIRuntime
import TTMOpenAPI
import TTMService

extension TTMApi {
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
}
