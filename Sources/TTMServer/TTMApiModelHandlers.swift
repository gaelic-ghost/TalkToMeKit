import Foundation
import OpenAPIRuntime
import TTMOpenAPI
import TTMService

extension TTMApi {
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
}
