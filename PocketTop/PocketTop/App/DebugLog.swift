import Foundation

nonisolated let pocketTopDebugEnabled: Bool = true

nonisolated func dbg(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    guard pocketTopDebugEnabled else { return }
    let name = (file as NSString).lastPathComponent
    print("[PocketTop] \(name):\(line) — \(message())")
}
