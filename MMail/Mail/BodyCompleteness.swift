import Foundation

/// Pure decision core for message-body completeness (no IMAP, no AppModel — unit
/// testable without a live server). Completeness is the contract that fixes the
/// 64 KB preview-prefetch truncation bug: a capped prefetch can leave a body
/// loaded-but-truncated, so opening such a message must trigger a full fetch.
enum BodyFetch {
    /// Was the returned body the WHOLE message?
    /// - An **uncapped** fetch (`byteLimit == nil`) is complete unconditionally —
    ///   the whole message was requested.
    /// - A **capped** fetch is complete ONLY when the server returned strictly
    ///   fewer bytes than the cap (proving end-of-message was reached). A count
    ///   equal to the cap is treated as possibly-truncated. The exact-boundary
    ///   case (raw size == cap) is a benign false-incomplete: it costs at most
    ///   one extra uncapped fetch on open, and can NEVER mark a truncated body
    ///   as complete.
    static func isComplete(returnedBytes: Int, byteLimit: Int?) -> Bool {
        guard let cap = byteLimit else { return true }
        return returnedBytes < cap
    }

    /// Should opening a message trigger a full (uncapped) body fetch?
    /// True when the body is absent (`!bodyLoaded`) OR loaded-but-not-complete
    /// (`bodyComplete != true`, which includes a legacy `nil`). A `guard` in the
    /// open path proceeds (fetches) only when this is true.
    static func needsFullFetch(bodyLoaded: Bool, bodyComplete: Bool?) -> Bool {
        return !bodyLoaded || !(bodyComplete ?? false)
    }
}
