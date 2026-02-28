import Testing
@testable import TTMService

struct TTMQwenRuntimeEnvironmentTests {
	@Test("runtime environment uses defaults when keys are missing")
	func defaultsWhenMissing() {
		let env = TTMQwenRuntimeEnvironment.fromEnvironment([:])
		#expect(env.debugEnabled == false)
		#expect(env.deviceMap == nil)
		#expect(env.torchDtype == nil)
		#expect(env.allowFallback == nil)
		#expect(env.enableFinalize == false)
	}

	@Test("runtime environment parses flags")
	func parsesFlags() {
		let env = TTMQwenRuntimeEnvironment.fromEnvironment([
			"TTM_QWEN_DEBUG": "1",
			"TTM_QWEN_DEVICE_MAP": "cpu",
			"TTM_QWEN_TORCH_DTYPE": "float32",
			"TTM_QWEN_ALLOW_FALLBACK": "0",
			"TTM_PYTHON_ENABLE_FINALIZE": "1",
		])
		#expect(env.debugEnabled)
		#expect(env.deviceMap == "cpu")
		#expect(env.torchDtype == "float32")
		#expect(env.allowFallback == false)
		#expect(env.enableFinalize)
	}
}
