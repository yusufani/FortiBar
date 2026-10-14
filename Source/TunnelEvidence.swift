import Foundation
import Darwin

struct TunnelAddress: Equatable {
    let interface: String
    let ip: String
}

func tunnelAddresses() -> [TunnelAddress] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return [] }
    defer { freeifaddrs(first) }
    var result: [TunnelAddress] = []
    var cursor = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        let name = String(cString: entry.pointee.ifa_name)
        guard name.hasPrefix("utun"),
              entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        result.append(TunnelAddress(interface: name, ip: String(cString: host)))
    }
    return result
}

func hasTunnelRoute(ip: String, addresses: [TunnelAddress], routes: String) -> Bool {
    let interfaces = Set(addresses.filter { $0.ip == ip }.map(\.interface))
    return routes.split(separator: "\n").contains { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 4 else { return false }
        return interfaces.contains(fields[3]) && fields[2].contains("U") && fields[2].contains("G")
    }
}

func activeTunnelMatches(_ ip: String) -> Bool {
    let addresses = tunnelAddresses()
    guard addresses.contains(where: { $0.ip == ip }) else { return false }
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    task.arguments = ["-rn", "-f", "inet"]
    task.standardOutput = output; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return false }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0, let routes = String(data: data, encoding: .utf8) else { return false }
    return hasTunnelRoute(ip: ip, addresses: addresses, routes: routes)
}
