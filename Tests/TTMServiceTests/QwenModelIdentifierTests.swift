import Testing
@testable import TTMService

struct QwenModelIdentifierTests {
	@Test("fallback order prefers same-mode models before cross-mode models")
	func fallbackOrderPrefersSameMode() {
		let order = QwenModelIdentifier.fallbackOrder(for: .customVoice1_7B)
		#expect(order.first == .customVoice1_7B)
		#expect(order[1] == .customVoice0_6B)

		let firstCrossModeIndex = order.firstIndex { $0.mode != .customVoice } ?? -1
		#expect(firstCrossModeIndex >= 2)
	}
}
