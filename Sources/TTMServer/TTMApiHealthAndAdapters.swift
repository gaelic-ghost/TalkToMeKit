import Foundation
import OpenAPIRuntime
import TTMOpenAPI

extension TTMApi {
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
}
