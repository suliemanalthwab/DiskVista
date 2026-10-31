import Foundation
import CryptoKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Config/App.plist")), format: nil) as! [String: Any]
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as! String)!)
let feed = try Data(contentsOf: root.appendingPathComponent("dist/appcast.xml"))
let text = String(decoding: feed, as: UTF8.self)
func capture(_ pattern: String) -> String {
    let regex = try! NSRegularExpression(pattern: pattern)
    let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))!
    return String(text[Range(match.range(at: 1), in: text)!])
}
let length = Int(capture("length: ([0-9]+)"))!
let feedSignature = Data(base64Encoded: capture("edSignature: ([A-Za-z0-9+/=]+)"))!
let signedFeed = Data(feed.prefix(length))
assert(key.isValidSignature(feedSignature, for: signedFeed), "Invalid feed signature")
var alteredFeed = signedFeed; alteredFeed[0] ^= 1
assert(!key.isValidSignature(feedSignature, for: alteredFeed), "Modified feed was accepted")
let xml = try XMLDocument(data: feed)
let enclosure = try xml.nodes(forXPath: "//enclosure").first as! XMLElement
let signature = Data(base64Encoded: enclosure.attribute(forName: "sparkle:edSignature")!.stringValue!)!
let archive = try Data(contentsOf: root.appendingPathComponent("dist/DiskVista-macOS.zip"))
assert(key.isValidSignature(signature, for: archive), "Invalid archive signature")
assert(archive.count == Int(enclosure.attribute(forName: "length")!.stringValue!))
var alteredArchive = archive; alteredArchive[alteredArchive.count - 1] ^= 1
assert(!key.isValidSignature(signature, for: alteredArchive), "Modified archive was accepted")
let version = plist["CFBundleShortVersionString"] as! String
assert(enclosure.attribute(forName: "url")!.stringValue! == "https://github.com/suliemanalthwab/DiskVista/releases/download/v\(version)/DiskVista-macOS.zip")
let feedVersion = try xml.nodes(forXPath: "//*[local-name()='version']").first!.stringValue
assert(feedVersion == plist["CFBundleVersion"] as? String)
assert(plist["SURequireSignedFeed"] as? Bool == true)
assert(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
assert(plist["SUEnableAutomaticChecks"] as? Bool == true)
print("PASS: public-key verification, feed and archive tamper rejection, archive length, release URL, version, security settings")
