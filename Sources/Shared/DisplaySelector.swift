import CoreGraphics
import ScreenCaptureKit

protocol DisplayIdentifiable {
    var displayID: CGDirectDisplayID { get }
}
extension SCDisplay: DisplayIdentifiable {}

enum DisplaySelector {
    static func main<D: DisplayIdentifiable>(from displays: [D], preferring mainID: CGDirectDisplayID) -> D? {
        displays.first { $0.displayID == mainID } ?? displays.first
    }
}
