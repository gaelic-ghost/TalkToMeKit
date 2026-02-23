//
//  TTMApi.swift
//  TalkToMeKit
//
//  Created by Gale Williams on 2/22/26.
//

import Foundation
import Logging
import OpenAPIRuntime
import TTMOpenAPI
import TTMPythonBridge
import TTMService

struct TTMApi: APIProtocol {
	private let qwenService: TTMQwenService?
	private let logger: Logger

	init(qwenService: TTMQwenService? = nil, logger: Logger = .init(label: "TalkToMeKit.TTMApi")) {
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
			apiVersion: "0.1.0",
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
		let payload = Components.Schemas.AdapterStatusResponse(
			adapterId: input.path.adapterId,
			modelId: "qwen3-tts",
			loaded: status.modelLoaded,
			loading: false,
			soxAvailable: true,
			qwenTtsAvailable: qwenService != nil,
			idleUnloadSeconds: 0,
			autoUnloadEnabled: false,
			ready: status.ready,
			detail: qwenStatusDetail(status: status)
		)
		return .ok(.init(body: .json(payload)))
	}

	func modelStatusModelStatusGet(_ input: TTMOpenAPI.Operations.ModelStatusModelStatusGet.Input) async throws -> TTMOpenAPI.Operations.ModelStatusModelStatusGet.Output {
		_ = input
		let status = await currentStatus()
		let payload = Components.Schemas.ModelStatusResponse(
			modelId: "qwen3-tts",
			loaded: status.modelLoaded,
			loading: false,
			soxAvailable: true,
			qwenTtsAvailable: qwenService != nil,
			idleUnloadSeconds: 0,
			autoUnloadEnabled: false,
			ready: status.ready,
			detail: qwenStatusDetail(status: status)
		)
		return .ok(.init(body: .json(payload)))
	}

	func modelLoadModelLoadPost(_ input: TTMOpenAPI.Operations.ModelLoadModelLoadPost.Input) async throws -> TTMOpenAPI.Operations.ModelLoadModelLoadPost.Output {
		_ = input
		guard let qwenService else {
			let payload = unloadedModelStatusResponse(detail: "Qwen3-TTS service is disabled; start server with --python-runtime-root")
			return .accepted(.init(body: .json(payload)))
		}

		do {
			let loaded = try await qwenService.loadModel()
			let status = await qwenService.status()
			let payload = modelStatusResponse(
				modelLoaded: loaded,
				ready: status.ready,
				detail: qwenStatusDetail(status: status)
			)
			return loaded ? .ok(.init(body: .json(payload))) : .accepted(.init(body: .json(payload)))
		} catch {
			let status = await currentStatus()
			let payload = unloadedModelStatusResponse(detail: qwenStatusDetail(status: status))
			return .accepted(.init(body: .json(payload)))
		}
	}

	func modelUnloadModelUnloadPost(_ input: TTMOpenAPI.Operations.ModelUnloadModelUnloadPost.Input) async throws -> TTMOpenAPI.Operations.ModelUnloadModelUnloadPost.Output {
		_ = input
		guard let qwenService else {
			let payload = unloadedModelStatusResponse(detail: "Qwen3-TTS service is disabled; start server with --python-runtime-root")
			return .ok(.init(body: .json(payload)))
		}

		do {
			_ = try await qwenService.unloadModel()
		} catch {
			// Keep endpoint idempotent; report unloaded status either way.
		}
		let status = await currentStatus()
		let payload = unloadedModelStatusResponse(detail: qwenStatusDetail(status: status))
		return .ok(.init(body: .json(payload)))
	}

	func synthesizeSynthesizePost(_ input: TTMOpenAPI.Operations.SynthesizeSynthesizePost.Input) async throws -> TTMOpenAPI.Operations.SynthesizeSynthesizePost.Output {
		let request = requestBody(from: input.body)
		guard isSupportedAudioFormat(request.format) else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}
		guard await qwenService.isReady() else {
			return .serviceUnavailable
		}

		let startedAt = Date()
		let qwenRequest = makeQwenRequest(from: request)
		logger.info(
			"Starting synthesis request",
			metadata: [
				"textLength": "\(qwenRequest.text.count)",
				"voice": "\(qwenRequest.voice ?? "")",
				"timeoutSeconds": "\(Self.synthesisTimeoutSeconds)",
			]
		)

		do {
			let wavBytes = try await synthesizeWithTimeout(request: qwenRequest, qwenService: qwenService)
			let elapsed = Date().timeIntervalSince(startedAt)
			logger.info(
				"Synthesis request completed",
				metadata: [
					"elapsedMs": "\(Int((elapsed * 1_000).rounded()))",
					"wavBytes": "\(wavBytes.count)",
				]
			)
			let body = HTTPBody(wavBytes)
			return .ok(.init(body: .audioWav(body)))
		} catch is SynthesisTimeoutError {
			logger.error(
				"Synthesis request timed out",
				metadata: [
					"timeoutSeconds": "\(Self.synthesisTimeoutSeconds)",
				]
			)
			return .serviceUnavailable
		} catch {
			let elapsed = Date().timeIntervalSince(startedAt)
			logger.error(
				"Synthesis request failed",
				metadata: [
					"elapsedMs": "\(Int((elapsed * 1_000).rounded()))",
					"error": "\(String(describing: error))",
				]
			)
			return .internalServerError
		}
	}

	func synthesizeStreamSynthesizeStreamPost(_ input: TTMOpenAPI.Operations.SynthesizeStreamSynthesizeStreamPost.Input) async throws -> TTMOpenAPI.Operations.SynthesizeStreamSynthesizeStreamPost.Output {
		let request = streamRequestBody(from: input.body)
		guard isSupportedAudioFormat(request.format) else {
			return .badRequest
		}
		guard let qwenService else {
			return .serviceUnavailable
		}
		guard await qwenService.isReady() else {
			return .serviceUnavailable
		}

		let startedAt = Date()
		let qwenRequest = makeQwenRequest(from: request)
		logger.info(
			"Starting stream synthesis request",
			metadata: [
				"textLength": "\(qwenRequest.text.count)",
				"voice": "\(qwenRequest.voice ?? "")",
				"timeoutSeconds": "\(Self.synthesisTimeoutSeconds)",
			]
		)

		do {
			let wavBytes = try await synthesizeWithTimeout(request: qwenRequest, qwenService: qwenService)
			let elapsed = Date().timeIntervalSince(startedAt)
			logger.info(
				"Stream synthesis request completed",
				metadata: [
					"elapsedMs": "\(Int((elapsed * 1_000).rounded()))",
					"wavBytes": "\(wavBytes.count)",
				]
			)
			let body = HTTPBody(wavBytes)
			return .ok(.init(body: .audioWav(body)))
		} catch is SynthesisTimeoutError {
			logger.error(
				"Stream synthesis request timed out",
				metadata: [
					"timeoutSeconds": "\(Self.synthesisTimeoutSeconds)",
				]
			)
			return .serviceUnavailable
		} catch {
			let elapsed = Date().timeIntervalSince(startedAt)
			logger.error(
				"Stream synthesis request failed",
				metadata: [
					"elapsedMs": "\(Int((elapsed * 1_000).rounded()))",
					"error": "\(String(describing: error))",
				]
			)
			return .internalServerError
		}
	}

	private func requestBody(from body: TTMOpenAPI.Operations.SynthesizeSynthesizePost.Input.Body) -> Components.Schemas.SynthesizeRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func streamRequestBody(from body: TTMOpenAPI.Operations.SynthesizeStreamSynthesizeStreamPost.Input.Body) -> Components.Schemas.SynthesizeRequest {
		switch body {
		case let .json(request):
			return request
		}
	}

	private func unloadedModelStatusResponse(detail: String) -> Components.Schemas.ModelStatusResponse {
		modelStatusResponse(modelLoaded: false, ready: false, detail: detail)
	}

	private func modelStatusResponse(
		modelLoaded: Bool,
		ready: Bool,
		detail: String
	) -> Components.Schemas.ModelStatusResponse {
		.init(
			modelId: "qwen3-tts",
			loaded: modelLoaded,
			loading: false,
			soxAvailable: true,
			qwenTtsAvailable: qwenService != nil,
			idleUnloadSeconds: 0,
			autoUnloadEnabled: false,
			ready: ready,
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

	private func makeQwenRequest(from request: Components.Schemas.SynthesizeRequest) -> QwenSynthesisRequest {
		.init(
			text: request.text,
			voice: request.instruct ?? request.language
		)
	}

	private func currentStatus() async -> TTMPythonBridgeStatus {
		guard let qwenService else {
			return .init(
				runtimeInitialized: false,
				moduleLoaded: false,
				modelLoaded: false,
				ready: false,
				lastError: nil
			)
		}
		return await qwenService.status()
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

	private func synthesizeWithTimeout(
		request: QwenSynthesisRequest,
		qwenService: TTMQwenService
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
