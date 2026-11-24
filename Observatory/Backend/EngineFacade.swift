import Foundation

/// The seam between the console and the radio engine. The live implementation wraps the C++
/// engine; tests use a fake. Every call is on the main thread.
@MainActor
protocol EngineFacade: AnyObject {
    func readState() -> EngineState
    /// Registers the one change handler.
    func observe(_ onChange: @escaping @MainActor (EngineChange) -> Void)
    func perform(_ calls: [EngineCall])
    /// Moves the locked CTUN display centre (`HL2Stream::setCtuneCenterHz`).
    func setCtuneCenter(_ hz: UInt32)
    /// Writes the zoom preference the engine's zoom binding follows (`Prefs::setZoom`).
    func setZoomPreference(_ zoom: Double)
    func quitApplication()
}
