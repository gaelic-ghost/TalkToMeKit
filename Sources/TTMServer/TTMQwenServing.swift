import Foundation
import TTMPythonBridge
import TTMService

protocol TTMQwenServing: Sendable {
	func synthesize(_ request: QwenSynthesisRequest) async throws -> Data
	func isReady() async -> Bool
	func status() async -> TTMPythonBridgeStatus
	func loadModel(selection: QwenModelSelection, strict: Bool) async throws -> Bool
	func unloadModel() async throws -> Bool
	func supportedCustomVoiceSpeakers(modelID: QwenModelIdentifier) async throws -> [String]
	func modelInventory() async -> [TTMModelInventoryItem]
}

extension TTMQwenService: TTMQwenServing {}
