import Foundation

/// The one error every `IronPetAPI` call throws. A client branches on `code` and shows `message`.
/// Both are plain strings on the wire, so a later network transport can send the error unchanged.
struct APIError: Error, Codable, Equatable, LocalizedError {
    enum Code: String, Codable, CaseIterable {
        /// The id in the request names nothing.
        case notFound = "not_found"
        /// A field is missing, out of range or not allowed.
        case invalid
        /// The request is valid but the current state refuses it, such as closing a task that is closed.
        case conflict
        /// The part of the app that serves the call is off, missing a permission or not running.
        case unavailable
        /// Anything else, with the cause in `message`.
        case failed
    }

    let code: Code
    let message: String

    var errorDescription: String? { message }

    static func notFound(_ message: String) -> APIError { APIError(code: .notFound, message: message) }
    static func invalid(_ message: String) -> APIError { APIError(code: .invalid, message: message) }
    static func conflict(_ message: String) -> APIError { APIError(code: .conflict, message: message) }
    static func unavailable(_ message: String) -> APIError { APIError(code: .unavailable, message: message) }
    static func failed(_ message: String) -> APIError { APIError(code: .failed, message: message) }

    /// Wraps any error a store throws. An `APIError` passes through unchanged.
    static func wrap(_ error: Error) -> APIError {
        (error as? APIError) ?? APIError(code: .failed, message: error.localizedDescription)
    }
}
