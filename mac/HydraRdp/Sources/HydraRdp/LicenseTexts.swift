import Foundation
import HydraRdpCore

enum LicenseTexts {
    struct Component {
        var title: String
        var fileName: String
    }

    static let components = [
        Component(title: "FreeRDP 3.33.1, including WinPR — Apache License 2.0", fileName: "FreeRDP-LICENSE.txt"),
        Component(title: "OpenSSL 3.5.9 — Apache License 2.0", fileName: "OpenSSL-LICENSE.txt"),
        Component(title: "json-c 0.19 — MIT License", fileName: "json-c-COPYING.txt")
    ]

    static func load(bundle: Bundle = .main) -> (version: String, body: String, complete: Bool) {
        var parts: [String] = []
        var sections: [String] = []
        var complete = true
        for component in components {
            let base = (component.fileName as NSString).deletingPathExtension
            let ext = (component.fileName as NSString).pathExtension
            let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "Licenses")
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                complete = false
                sections.append("\(component.title)\n\nThe license file \(component.fileName) was not included in this copy of the app.")
                continue
            }
            parts.append(text)
            sections.append("\(component.title)\n\n\(text)")
        }
        let version = complete ? InstallerRules.noticesVersion(parts: parts) : ""
        return (version, sections.joined(separator: "\n\n----------\n\n"), complete)
    }
}
