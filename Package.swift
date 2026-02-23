// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TalkToMeKit",
	platforms: [
		.macOS(.v15),
	],
	products: [
		.executable(
			name: "TTMServer",
			targets: [ "TTMServer" ]
		),
	    .library(
	        name: "TTMService",
	        targets: [ "TTMService" ]
	    ),
	    .executable(
	        name: "ttm-cli",
	        targets: [ "TTMCli" ]
	    ),
	],
    dependencies: [
		.package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.10.0"),
		.package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird.git", from: "2.0.0"),
		.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.10.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
		.target(
			name: "TTMOpenAPI",
			dependencies: [
				.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
			],
			plugins: [
				.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
			]
		),
		.executableTarget(
			name: "TTMServer",
			dependencies: [
				.product(name: "Hummingbird", package: "hummingbird"),
				.product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.target(name: "TTMOpenAPI"),
				.target(name: "TTMService"),
			]
		),
		.target(
			name: "TTMService",
			dependencies: [
				.product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
				.target(name: "TTMPythonRuntimeBundle"),
			],
			resources: [
				.process("Resources"),
			]
		),
		.executableTarget(
			name: "TTMCli",
			dependencies: [
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			]
		),
		.testTarget(
			name: "TTMServiceTests",
			dependencies: [
				.target(name: "TTMService"),
				.target(name: "TTMPythonRuntimeBundle"),
			]
		),
		.testTarget(
			name: "TTMServerTests",
			dependencies: [
				.target(name: "TTMServer"),
				.target(name: "TTMOpenAPI"),
				.target(name: "TTMService"),
			]
		),
		.target(
			name: "TTMPythonRuntimeBundle",
			resources: [
				.copy("Resources/Runtime"),
			]
		),
		.plugin(
			name: "StagePythonRuntimePlugin",
			capability: .command(
				intent: .custom(
					verb: "stage-python-runtime",
					description: "Stage local Python runtime/model assets for TalkToMeKit development."
				),
				permissions: [
					.allowNetworkConnections(
						scope: .all(),
						reason: "Download Python packages and optional Qwen model assets during runtime staging."
					),
					.writeToPackageDirectory(reason: "Stage runtime assets under Sources/TTMPythonRuntimeBundle/Resources/Runtime/current."),
				]
			)
		),
    ]
)
