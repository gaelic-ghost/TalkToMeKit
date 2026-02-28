import Foundation
import Logging
import OpenAPIRuntime
import TTMOpenAPI
import TTMService

struct TTMApi: APIProtocol {
	let qwenService: (any TTMQwenServing)?
	let logger: Logger
	let environment: TTMServerEnvironment

	init(
		qwenService: (any TTMQwenServing)? = nil,
		logger: Logger = .init(label: "TalkToMeKit.TTMApi"),
		environment: TTMServerEnvironment = .fromProcessInfo()
	) {
		self.qwenService = qwenService
		self.logger = logger
		self.environment = environment
	}
}
