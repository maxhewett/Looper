import Foundation

public enum LooperError: LocalizedError, CustomStringConvertible {
    case hashMismatch(package: String, expected: String, actual: String)
    case downloadFailed(String)
    case incompleteDownload(received: Int64, expected: Int64)
    case insufficientStorage(String)
    case installFailed(status: Int32, message: String)
    case packageNotInstalled(String)
    case deleteFailed(identifier: String, message: String)
    case catalogueUnavailable(String)
    case scheduleFailed(String)
    case missingArgument(String)
    case unknownCommand(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case let .hashMismatch(package, expected, actual):
            return "\(package) failed SHA-256 verification. Expected \(expected), got \(actual)."
        case let .downloadFailed(message):
            return "Download failed: \(message)"
        case let .incompleteDownload(received, expected):
            return "Download is incomplete: received \(received) of \(expected) bytes."
        case let .insufficientStorage(message):
            return "Insufficient storage: \(message)"
        case let .installFailed(status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "installer exited with status \(status)."
            }
            return "installer exited with status \(status): \(detail)"
        case let .packageNotInstalled(identifier):
            return "\(identifier) is not installed."
        case let .deleteFailed(identifier, message):
            return "Could not delete \(identifier): \(message)"
        case let .catalogueUnavailable(message):
            return "Apple catalogue unavailable: \(message)"
        case let .scheduleFailed(message):
            return "Could not update the schedule: \(message)"
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)."
        case let .unknownCommand(command):
            return "Unknown command: \(command)."
        }
    }
}
