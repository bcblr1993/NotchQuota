import Foundation

enum ResourceLocator {
    static func icon(_ name: String) -> URL? {
        let embedded = Bundle.main.resourceURL?.appendingPathComponent("NotchQuota_NotchQuota.bundle")
        if let embedded, let bundle = Bundle(url: embedded), let icon = bundle.url(forResource: name, withExtension: "png") { return icon }
        return Bundle.module.url(forResource: name, withExtension: "png")
    }
}
