import Foundation

/// Optional sink for collector failures. The menu-bar app points this at its log.
/// Hydra AVD Client leaves it unset so a missing lookup is only an error string on the snapshot.
public enum CollectorDiagnostics {
    public static var recordError: ((String) -> Void)?
}
