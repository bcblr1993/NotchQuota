import Foundation

/// The pairing wire format carries whole milliseconds.
///
/// Protocol values are normalised the moment they are constructed, so a sealed
/// payload compares equal to the value it decodes back into. Without that the
/// phone cannot tell "the Mac sent something new" from "the same bundle lost a
/// few bits in transit", and would rewrite the keychain and reload widget
/// timelines on every sync.
public extension Date {
    var wireMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(wireMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(wireMilliseconds) / 1000)
    }

    /// Idempotent: truncating an already truncated date is a no-op.
    var wireTruncated: Date { Date(wireMilliseconds: wireMilliseconds) }
}
