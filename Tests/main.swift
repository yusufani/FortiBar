import Foundation

let parsed = parseConnectionInfo("VPN Name Office VPN IP Address 192.0.2.5")
assert(parsed == ConnectionInfo(profile: "Office VPN", ip: "192.0.2.5"))
assert(parsed?.profile != "Office")
assert(parsed?.profile != "Office VPN backup")
assert(parseConnectionInfo("VPN Name\n Office VPN \nIP Address\n192.0.2.25")?.profile == "Office VPN")
assert(parseConnectionInfo("No VPN Connected") == nil)
assert(parseConnectionInfo("VPN Name Office VPN IP Address 999.2.3.4") == nil)
assert(parseConnectionInfo("VPN Name Office VPN IP Address 192.0.2.1234") == nil)
assert(parseConnectionInfo("VPN Name  IP Address 192.0.2.5") == nil)
print("8 connection identity and address checks passed")
