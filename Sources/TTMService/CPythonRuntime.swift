import Darwin
import Foundation

final class CPythonRuntime: @unchecked Sendable {
	private typealias PyObject = OpaquePointer
	private typealias PyGILStateState = Int32
	private typealias PyThreadState = UnsafeMutableRawPointer

	private typealias PyInitializeExFn = @convention(c) (Int32) -> Void
	private typealias PyFinalizeExFn = @convention(c) () -> Int32
	private typealias PyIsInitializedFn = @convention(c) () -> Int32
	private typealias PyImportImportModuleFn = @convention(c) (UnsafePointer<CChar>) -> PyObject?
	private typealias PyObjectGetAttrStringFn = @convention(c) (PyObject?, UnsafePointer<CChar>) -> PyObject?
	private typealias PyCallableCheckFn = @convention(c) (PyObject?) -> Int32
	private typealias PyTupleNewFn = @convention(c) (Int) -> PyObject?
	private typealias PyTupleSetItemFn = @convention(c) (PyObject?, Int, PyObject?) -> Int32
	private typealias PyUnicodeFromStringFn = @convention(c) (UnsafePointer<CChar>) -> PyObject?
	private typealias PyLongFromLongFn = @convention(c) (Int) -> PyObject?
	private typealias PyBytesFromStringAndSizeFn = @convention(c) (UnsafePointer<CChar>?, Int) -> PyObject?
	private typealias PyObjectCallObjectFn = @convention(c) (PyObject?, PyObject?) -> PyObject?
	private typealias PyObjectIsTrueFn = @convention(c) (PyObject?) -> Int32
	private typealias PyBytesAsStringAndSizeFn = @convention(c) (PyObject?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?) -> Int32
	private typealias PyUnicodeAsUTF8Fn = @convention(c) (PyObject?) -> UnsafePointer<CChar>?
	private typealias PyDecRefFn = @convention(c) (PyObject?) -> Void
	private typealias PyErrPrintExFn = @convention(c) (Int32) -> Void
	private typealias PyGILStateEnsureFn = @convention(c) () -> PyGILStateState
	private typealias PyGILStateReleaseFn = @convention(c) (PyGILStateState) -> Void
	private typealias PyEvalSaveThreadFn = @convention(c) () -> PyThreadState?
	private typealias PyEvalRestoreThreadFn = @convention(c) (PyThreadState?) -> Void

	private let handle: UnsafeMutableRawPointer
	private let pyInitializeEx: PyInitializeExFn
	private let pyFinalizeEx: PyFinalizeExFn
	private let pyIsInitialized: PyIsInitializedFn
	private let pyImportImportModule: PyImportImportModuleFn
	private let pyObjectGetAttrString: PyObjectGetAttrStringFn
	private let pyCallableCheck: PyCallableCheckFn
	private let pyTupleNew: PyTupleNewFn
	private let pyTupleSetItem: PyTupleSetItemFn
	private let pyUnicodeFromString: PyUnicodeFromStringFn
	private let pyLongFromLong: PyLongFromLongFn
	private let pyBytesFromStringAndSize: PyBytesFromStringAndSizeFn
	private let pyObjectCallObject: PyObjectCallObjectFn
	private let pyObjectIsTrue: PyObjectIsTrueFn
	private let pyBytesAsStringAndSize: PyBytesAsStringAndSizeFn
	private let pyUnicodeAsUTF8: PyUnicodeAsUTF8Fn
	private let pyDecRef: PyDecRefFn
	private let pyErrPrintEx: PyErrPrintExFn
	private let pyGILStateEnsure: PyGILStateEnsureFn
	private let pyGILStateRelease: PyGILStateReleaseFn
	private let pyEvalSaveThread: PyEvalSaveThreadFn
	private let pyEvalRestoreThread: PyEvalRestoreThreadFn
	private var releasedThreadState: PyThreadState?

	init(libraryPath: String) throws {
		guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_GLOBAL) else {
			throw TTMPythonBridgeError.pythonLibraryLoadFailed(path: libraryPath)
		}
		self.handle = handle

		pyInitializeEx = try Self.loadSymbol(handle: handle, "Py_InitializeEx", as: PyInitializeExFn.self)
		pyFinalizeEx = try Self.loadSymbol(handle: handle, "Py_FinalizeEx", as: PyFinalizeExFn.self)
		pyIsInitialized = try Self.loadSymbol(handle: handle, "Py_IsInitialized", as: PyIsInitializedFn.self)
		pyImportImportModule = try Self.loadSymbol(handle: handle, "PyImport_ImportModule", as: PyImportImportModuleFn.self)
		pyObjectGetAttrString = try Self.loadSymbol(handle: handle, "PyObject_GetAttrString", as: PyObjectGetAttrStringFn.self)
		pyCallableCheck = try Self.loadSymbol(handle: handle, "PyCallable_Check", as: PyCallableCheckFn.self)
		pyTupleNew = try Self.loadSymbol(handle: handle, "PyTuple_New", as: PyTupleNewFn.self)
		pyTupleSetItem = try Self.loadSymbol(handle: handle, "PyTuple_SetItem", as: PyTupleSetItemFn.self)
		pyUnicodeFromString = try Self.loadSymbol(handle: handle, "PyUnicode_FromString", as: PyUnicodeFromStringFn.self)
		pyLongFromLong = try Self.loadSymbol(handle: handle, "PyLong_FromLong", as: PyLongFromLongFn.self)
		pyBytesFromStringAndSize = try Self.loadSymbol(handle: handle, "PyBytes_FromStringAndSize", as: PyBytesFromStringAndSizeFn.self)
		pyObjectCallObject = try Self.loadSymbol(handle: handle, "PyObject_CallObject", as: PyObjectCallObjectFn.self)
		pyObjectIsTrue = try Self.loadSymbol(handle: handle, "PyObject_IsTrue", as: PyObjectIsTrueFn.self)
		pyBytesAsStringAndSize = try Self.loadSymbol(handle: handle, "PyBytes_AsStringAndSize", as: PyBytesAsStringAndSizeFn.self)
		pyUnicodeAsUTF8 = try Self.loadSymbol(handle: handle, "PyUnicode_AsUTF8", as: PyUnicodeAsUTF8Fn.self)
		pyDecRef = try Self.loadSymbol(handle: handle, "Py_DecRef", as: PyDecRefFn.self)
		pyErrPrintEx = try Self.loadSymbol(handle: handle, "PyErr_PrintEx", as: PyErrPrintExFn.self)
		pyGILStateEnsure = try Self.loadSymbol(handle: handle, "PyGILState_Ensure", as: PyGILStateEnsureFn.self)
		pyGILStateRelease = try Self.loadSymbol(handle: handle, "PyGILState_Release", as: PyGILStateReleaseFn.self)
		pyEvalSaveThread = try Self.loadSymbol(handle: handle, "PyEval_SaveThread", as: PyEvalSaveThreadFn.self)
		pyEvalRestoreThread = try Self.loadSymbol(handle: handle, "PyEval_RestoreThread", as: PyEvalRestoreThreadFn.self)
		releasedThreadState = nil
	}

	func configureEnvironment(_ configuration: PythonRuntimeConfiguration) throws {
		guard setenv("PYTHONHOME", configuration.pythonHome, 1) == 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
		let pythonPath = configuration.moduleSearchPaths.joined(separator: ":")
		guard setenv("PYTHONPATH", pythonPath, 1) == 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
	}

	func initialize() throws {
		// When finalization is disabled (default), CPython may already be process-initialized
		// by a prior bridge instance. Re-running PyEval_SaveThread in that state can crash.
		guard pyIsInitialized() == 0 else {
			releasedThreadState = nil
			return
		}
		pyInitializeEx(0)
		guard pyIsInitialized() != 0 else {
			throw TTMPythonBridgeError.pythonInitializeFailed
		}
		// Release the GIL after initialization so future calls from other threads can acquire it.
		releasedThreadState = pyEvalSaveThread()
	}

	func importModule(named name: String) throws {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = name.withCString { pyImportImportModule($0) }
		guard module != nil else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: name)
		}
	}

	func synthesize(moduleName: String, request: QwenSynthesisRequest) throws -> Data {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let functionName: String
		switch request.mode {
		case .voiceDesign:
			functionName = "synthesize_voice_design"
		case .customVoice:
			functionName = "synthesize_custom_voice"
		case .voiceClone:
			functionName = "synthesize_voice_clone"
		}
		let synthFn = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let synthFn else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(synthFn) }

		guard pyCallableCheck(synthFn) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

		let argumentCount: Int
		switch request.mode {
		case .voiceDesign:
			argumentCount = 5
		case .customVoice:
			argumentCount = 6
		case .voiceClone:
			argumentCount = 5
		}
		guard let args = pyTupleNew(argumentCount) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(args) }

		guard let textObject = request.text.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let languageObject = request.language.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let sampleRateObject = pyLongFromLong(request.sampleRate) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		guard let modelObject = request.modelID.rawValue.withCString({ pyUnicodeFromString($0) }) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		let instructValue = request.instruct ?? ""
		var instructObject: PyObject?
		var voiceObject: PyObject?
		var referenceAudioObject: PyObject?
		if request.mode != .voiceClone {
			guard let createdVoice = request.voice.withCString({ pyUnicodeFromString($0) }) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			voiceObject = createdVoice
		}
		if request.mode == .voiceClone {
			guard let referenceAudio = request.referenceAudio else {
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			let createdReferenceAudio = referenceAudio.withUnsafeBytes { rawBuffer -> PyObject? in
				let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
				return pyBytesFromStringAndSize(baseAddress, rawBuffer.count)
			}
			guard let createdReferenceAudio else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			referenceAudioObject = createdReferenceAudio
		}
		if request.mode == .customVoice {
			guard let created = instructValue.withCString({ pyUnicodeFromString($0) }) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			instructObject = created
		}

		// PyTuple_SetItem steals references on success.
		guard pyTupleSetItem(args, 0, textObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(textObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		switch request.mode {
		case .voiceDesign, .customVoice:
			guard let voiceObject else {
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			guard pyTupleSetItem(args, 1, voiceObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(voiceObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
		case .voiceClone:
			guard let referenceAudioObject else {
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			guard pyTupleSetItem(args, 1, referenceAudioObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(referenceAudioObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
		}
		let languageIndex = request.mode == .customVoice ? 3 : 2
		guard pyTupleSetItem(args, languageIndex, languageObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(languageObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		let sampleRateIndex = request.mode == .customVoice ? 4 : 3
		guard pyTupleSetItem(args, sampleRateIndex, sampleRateObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(sampleRateObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		let modelIndex = request.mode == .customVoice ? 5 : 4
		guard pyTupleSetItem(args, modelIndex, modelObject) == 0 else {
			pyErrPrintEx(0)
			pyDecRef(modelObject)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		if request.mode == .customVoice, let instructObject {
			guard pyTupleSetItem(args, 2, instructObject) == 0 else {
				pyErrPrintEx(0)
				pyDecRef(instructObject)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
		}

		guard let result = pyObjectCallObject(synthFn, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		var buffer: UnsafeMutablePointer<CChar>?
		var byteCount = 0
		guard pyBytesAsStringAndSize(result, &buffer, &byteCount) == 0 else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.invalidSynthesisReturnType
		}
		guard let buffer else {
			throw TTMPythonBridgeError.invalidSynthesisReturnType
		}

		return Data(bytes: buffer, count: byteCount)
	}

	func callBooleanFunction(moduleName: String, functionName: String, stringArguments: [String] = []) throws -> Bool {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let function = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let function else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(function) }

		guard pyCallableCheck(function) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

		var args: PyObject?
		if !stringArguments.isEmpty {
			guard let tuple = pyTupleNew(stringArguments.count) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			for (index, argument) in stringArguments.enumerated() {
				guard let argObject = argument.withCString({ pyUnicodeFromString($0) }) else {
					pyErrPrintEx(0)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
				guard pyTupleSetItem(tuple, index, argObject) == 0 else {
					pyErrPrintEx(0)
					pyDecRef(argObject)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
			}
			args = tuple
		}
		defer {
			if let args {
				pyDecRef(args)
			}
		}

		guard let result = pyObjectCallObject(function, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		let truthy = pyObjectIsTrue(result)
		guard truthy != -1 else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		return truthy != 0
	}

	func callStringFunction(moduleName: String, functionName: String, stringArguments: [String] = []) throws -> String {
		let state = pyGILStateEnsure()
		defer { pyGILStateRelease(state) }

		let module = moduleName.withCString { pyImportImportModule($0) }
		guard let module else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.qwenModuleImportFailed(module: moduleName)
		}
		defer { pyDecRef(module) }

		let function = functionName.withCString { pyObjectGetAttrString(module, $0) }
		guard let function else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(function) }

		guard pyCallableCheck(function) != 0 else {
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}

		var args: PyObject?
		if !stringArguments.isEmpty {
			guard let tuple = pyTupleNew(stringArguments.count) else {
				pyErrPrintEx(0)
				throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
			}
			for (index, argument) in stringArguments.enumerated() {
				guard let argObject = argument.withCString({ pyUnicodeFromString($0) }) else {
					pyErrPrintEx(0)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
				guard pyTupleSetItem(tuple, index, argObject) == 0 else {
					pyErrPrintEx(0)
					pyDecRef(argObject)
					pyDecRef(tuple)
					throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
				}
			}
			args = tuple
		}
		defer {
			if let args {
				pyDecRef(args)
			}
		}

		guard let result = pyObjectCallObject(function, args) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		defer { pyDecRef(result) }

		guard let utf8 = pyUnicodeAsUTF8(result) else {
			pyErrPrintEx(0)
			throw TTMPythonBridgeError.pythonCallFailed(function: functionName)
		}
		return String(cString: utf8)
	}

	func shutdown(shouldFinalize: Bool) {
		// CPython finalization is unsafe for long-lived native extensions (e.g. torch background threads).
		// Keep finalize/dlclose opt-in to avoid process crashes during shutdown/tests.
		guard shouldFinalize else {
			return
		}
		if pyIsInitialized() != 0 {
			if releasedThreadState != nil {
				pyEvalRestoreThread(releasedThreadState)
				releasedThreadState = nil
			}
			_ = pyFinalizeEx()
		}
		dlclose(handle)
	}

	private static func loadSymbol<T>(handle: UnsafeMutableRawPointer, _ symbol: String, as type: T.Type) throws -> T {
		guard let ptr = dlsym(handle, symbol) else {
			throw TTMPythonBridgeError.missingSymbol(name: symbol)
		}
		return unsafeBitCast(ptr, to: T.self)
	}
}
