#!/usr/bin/env swift
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class EnclosureParser: NSObject, XMLParserDelegate {
    var signatures: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        if elementName == "enclosure", let url = attributes["url"], let signature = attributes["sparkle:edSignature"] {
            signatures[URL(string: url)?.lastPathComponent ?? ""] = signature
        }
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        fputs("Usage: verify-update.swift appcast.xml archive.zip public-key\n", stderr)
        exit(2)
    }
    let feed = URL(fileURLWithPath: CommandLine.arguments[1])
    let archive = URL(fileURLWithPath: CommandLine.arguments[2])
    let delegate = EnclosureParser()
    let parser = XMLParser(data: try Data(contentsOf: feed))
    parser.delegate = delegate
    guard parser.parse(),
          let rawSignature = delegate.signatures[archive.lastPathComponent],
          let signature = Data(base64Encoded: rawSignature),
          let publicData = Data(base64Encoded: CommandLine.arguments[3])
    else { throw CocoaError(.fileReadCorruptFile) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    var data = try Data(contentsOf: archive)
    guard !data.isEmpty, key.isValidSignature(signature, for: data) else { throw CocoaError(.fileReadCorruptFile) }
    data[0] ^= 1
    guard !key.isValidSignature(signature, for: data) else { throw CocoaError(.fileReadCorruptFile) }
    print("Ed25519 archive signature verified against the embedded public key; tampered archive rejected")
} catch {
    fputs("Update signature verification failed: \(error)\n", stderr)
    exit(1)
}
