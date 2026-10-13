import Foundation

struct ConnectionInfo: Equatable {
    let profile: String
    let ip: String
}
func parseConnectionInfo(_ text: String) -> ConnectionInfo? {
    let pattern = #"VPN Name\s+(.+?)\s+IP Address\s+([0-9]{1,3}(?:\.[0-9]{1,3}){3})(?![0-9.])"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let profileRange = Range(match.range(at: 1), in: text),
          let ipRange = Range(match.range(at: 2), in: text) else { return nil }
    let profile = String(text[profileRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    let ip = String(text[ipRange])
    guard !profile.isEmpty, ip.split(separator: ".").allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
    return ConnectionInfo(profile: profile, ip: ip)
}
