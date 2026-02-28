import ArgumentParser

@main
struct TTMCliMain: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "ttm-cli",
		abstract: "CLI client for TalkToMeKit server APIs.",
		subcommands: [
			Health.self,
			Version.self,
			Status.self,
			Inventory.self,
			Adapters.self,
			AdapterStatus.self,
			Load.self,
			Unload.self,
			Speakers.self,
			Synthesize.self,
			Play.self,
		]
	)

	mutating func run() async throws {
		throw CleanExit.helpRequest(self)
	}
}
