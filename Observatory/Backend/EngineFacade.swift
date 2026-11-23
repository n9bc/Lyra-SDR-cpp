import Foundation

/// The seam between the console and the radio engine. The live implementation wraps the C++
/// engine; tests use a fake. Every call is on the main thread.
@MainActor
protocol EngineFacade: AnyObject {
    func readState() -> EngineState
    /// Registers the one change handler.
    func observe(_ onChange: @escaping @MainActor (EngineChange) -> Void)
    func perform(_ calls: [EngineCall])
    func quitApplication()
}
