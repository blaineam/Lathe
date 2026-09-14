import Foundation

/// Wheels, built byte by byte.
///
/// The same reasoning as the document suite's hand-written ZIPs: asking a tool
/// to produce the archive cannot reliably produce the *members that matter*. A
/// wheel with a `.so` in it, a wheel whose filename tags disagree with its
/// contents, a wheel with a `../` member — none of those are things a packaging
/// tool will make on request, and they are precisely what the installer's
/// refusals are about. So the archives here contain exactly what each test
/// claims they contain, with a real CRC per entry, stored (uncompressed) so the
/// bytes are inspectable.
///
/// No fixture is committed. Every one is a few hundred bytes assembled at run
/// time, which keeps the repository free of binaries whose provenance would need
/// explaining.
enum WheelFixtures {

    /// A wheel with the given member paths, each holding a one-line body.
    static func wheel(_ members: [String]) -> Data {
        StoredZIP.archive(members.map { ($0, Data("# \($0)\n".utf8)) })
    }

    /// The shape a real pure-Python wheel has: a package, and its `.dist-info`.
    static func pureWheel(distribution: String, version: String) -> (filename: String, data: Data) {
        let importName = distribution.replacingOccurrences(of: "-", with: "_")
        let distInfo = "\(importName)-\(version).dist-info"
        let data = StoredZIP.archive([
            ("\(importName)/__init__.py", Data("VERSION = \"\(version)\"\n".utf8)),
            ("\(importName)/core.py", Data("def greet():\n    return \"hello from \(importName)\"\n".utf8)),
            ("\(distInfo)/METADATA", Data("Metadata-Version: 2.1\nName: \(distribution)\nVersion: \(version)\n".utf8)),
            ("\(distInfo)/WHEEL", Data("Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n".utf8)),
        ])
        return ("\(importName)-\(version)-py3-none-any.whl", data)
    }
}

/// A minimal stored-method ZIP writer.
///
/// Stored rather than deflated on purpose: nothing here needs compression, and a
/// stored archive is one that can be read with a hex dump when a parser test
/// disagrees with a parser.
enum StoredZIP {

    static func archive(_ entries: [(name: String, contents: Data)]) -> Data {
        var output = Data()
        var directory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.contents)
            let offset = UInt32(output.count)

            // Local file header.
            output.append(uint32(0x0403_4b50))
            output.append(uint16(20))  // version needed
            output.append(uint16(0x0800))  // UTF-8 names
            output.append(uint16(0))  // stored
            output.append(uint16(0))  // modification time
            output.append(uint16(0x0021))  // modification date — 1980-01-01
            output.append(uint32(crc))
            output.append(uint32(UInt32(entry.contents.count)))
            output.append(uint32(UInt32(entry.contents.count)))
            output.append(uint16(UInt16(nameBytes.count)))
            output.append(uint16(0))  // extra field
            output.append(nameBytes)
            output.append(entry.contents)

            // Central directory header for the same entry.
            directory.append(uint32(0x0201_4b50))
            directory.append(uint16(20))  // version made by
            directory.append(uint16(20))  // version needed
            directory.append(uint16(0x0800))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0x0021))
            directory.append(uint32(crc))
            directory.append(uint32(UInt32(entry.contents.count)))
            directory.append(uint32(UInt32(entry.contents.count)))
            directory.append(uint16(UInt16(nameBytes.count)))
            directory.append(uint16(0))  // extra
            directory.append(uint16(0))  // comment
            directory.append(uint16(0))  // disk number
            directory.append(uint16(0))  // internal attributes
            directory.append(uint32(0))  // external attributes
            directory.append(uint32(offset))
            directory.append(nameBytes)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)

        // End of central directory.
        output.append(uint32(0x0605_4b50))
        output.append(uint16(0))  // this disk
        output.append(uint16(0))  // disk with the directory
        output.append(uint16(UInt16(entries.count)))
        output.append(uint16(UInt16(entries.count)))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(directoryOffset))
        output.append(uint16(0))  // comment length

        return output
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    /// The ordinary CRC-32, reflected, polynomial `0xEDB88320`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
