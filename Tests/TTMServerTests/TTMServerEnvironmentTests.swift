import Testing
@testable import TTMServer

struct TTMServerEnvironmentTests {
	@Test("server environment uses defaults when keys are missing")
	func defaultsWhenMissing() {
		let env = TTMServerEnvironment.fromEnvironment([:])
		#expect(env.synthesisTimeoutSeconds == 120)
		#expect(env.deviceMap == nil)
		#expect(env.torchDtype == nil)
		#expect(env.allowFallback == nil)
	}

	@Test("server environment parses valid timeout and fallback")
	func parsesValidValues() {
		let env = TTMServerEnvironment.fromEnvironment([
			"TTM_QWEN_SYNTH_TIMEOUT_SECONDS": "45",
			"TTM_QWEN_ALLOW_FALLBACK": "true",
			"TTM_QWEN_DEVICE_MAP": "auto",
			"TTM_QWEN_TORCH_DTYPE": "float16",
		])
		#expect(env.synthesisTimeoutSeconds == 45)
		#expect(env.allowFallback == true)
		#expect(env.deviceMap == "auto")
		#expect(env.torchDtype == "float16")
	}

	@Test("server environment ignores invalid timeout and fallback")
	func ignoresInvalidValues() {
		let env = TTMServerEnvironment.fromEnvironment([
			"TTM_QWEN_SYNTH_TIMEOUT_SECONDS": "-10",
			"TTM_QWEN_ALLOW_FALLBACK": "maybe",
		])
		#expect(env.synthesisTimeoutSeconds == 120)
		#expect(env.allowFallback == nil)
	}
}
