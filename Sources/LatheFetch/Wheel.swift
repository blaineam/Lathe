import CryptoKit
import Foundation

// MARK: - The filename

/// A wheel filename, taken apart.
///
/// PEP 427 puts the compatibility contract in the *filename*:
/// `{distribution}-{version}(-{build})?-{python}-{abi}-{platform}.whl`. That is
/// what makes a first-pass purity decision possible without reading the archive
/// at all, which matters when the alternative is downloading twenty megabytes to
/// find out.
public struct WheelName: Sendable, Equatable {

    /// The project name as the filename spells it — underscores, not hyphens.
    public let distribution: String
    public let version: String

    /// The optional build tag, which almost nothing uses.
    public let buildTag: String?

    /// `py3`, `cp313`, or a compressed set like `py2.py3`.
    public let pythonTags: [String]

    /// `none` for pure Python; `cp313`, `abi3` and friends for compiled.
    public let abiTags: [String]

    /// `any` for pure Python; `macosx_11_0_arm64` and friends for compiled.
    public let platformTags: [String]

    /// `true` when the tags claim the wheel is pure Python and
    /// platform-independent.
    ///
    /// A *claim*, and treated as one: ``WheelInspection`` checks the archive's
    /// contents as well. The tags are produced by the publisher's build tooling
    /// and are occasionally wrong — a project that ships a `.so` inside a
    /// `py3-none-any` wheel is rare, but a mis-tagged wheel that failed to
    /// import is exactly the confusing failure this installer is meant to
    /// replace with a sentence.
    public var claimsPurePython: Bool {
        abiTags.allSatisfy { $0 == "none" } && platformTags.allSatisfy { $0 == "any" }
    }

    public init(parsing filename: String) throws {
        guard filename.hasSuffix(".whl") else {
            throw PythonPackageError.malformedWheelName(filename, reason: "does not end in .whl")
        }
        let stem = String(filename.dropLast(".whl".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 || parts.count == 6 else {
            throw PythonPackageError.malformedWheelName(
                filename, reason: "expected 5 or 6 hyphen-separated components, found \(parts.count)")
        }
        guard parts.allSatisfy({ !$0.isEmpty }) else {
            throw PythonPackageError.malformedWheelName(filename, reason: "has an empty component")
        }

        distribution = parts[0]
        version = parts[1]
        buildTag = parts.count == 6 ? parts[2] : nil
        pythonTags = parts[parts.count - 3].split(separator: ".").map(String.init)
        abiTags = parts[parts.count - 2].split(separator: ".").map(String.init)
        platformTags = parts[parts.count - 1].split(separator: ".").map(String.init)
    }

    /// The `.dist-info` directory this wheel installs, per PEP 427.
    public var distInfoDirectory: String { "\(distribution)-\(version).dist-info" }
}

// MARK: - The archive

/// What is actually inside a wheel.
///
/// Reads the ZIP **central directory only**: the member list, uncompressed, at
/// the end of the file. That is enough to decide purity and to reject unsafe
/// paths, and it needs no decompressor — which is what lets this run, and be
/// tested, with no interpreter present.
public struct WheelInspection: Sendable, Equatable {

    public let name: WheelName

    /// Every member path in the archive.
    public let members: [String]

    /// Members that are compiled extension modules or shared libraries.
    public let compiledExtensions: [String]

    /// Members that would extract outside the destination directory.
    public let unsafeMembers: [String]

    /// The lowercase hex SHA-256 of the archive bytes.
    public let sha256: String

    /// `true` only when both the tags and the contents agree.
    public var isPurePython: Bool { name.claimsPurePython && compiledExtensions.isEmpty }

    /// Suffixes that mean machine code. `.so` covers CPython extension modules
    /// on every Unix including iOS; `.pyd` is the Windows spelling and appears
    /// in cross-platform wheels; `.dylib` and `.a` show up in wheels that bundle
    /// a native library beside the extension that loads it.
    static let compiledSuffixes = [".so", ".pyd", ".dylib", ".a"]

    /// Inspects `data` as the wheel named `filename`.
    public static func inspect(_ data: Data, filename: String) throws -> WheelInspection {
        let name = try WheelName(parsing: filename)
        let members = try ZIPCentralDirectory.memberNames(in: data)

        let compiled = members.filter { member in
            let lowered = member.lowercased()
            // `.libs/` and `.dylibs/` are where auditwheel and delocate park the
            // bundled native libraries a compiled wheel drags along. A wheel
            // containing one is not pure however its members are named.
            if lowered.contains(".libs/") || lowered.contains(".dylibs/") { return true }
            return compiledSuffixes.contains { lowered.hasSuffix($0) }
        }

        return WheelInspection(
            name: name,
            members: members,
            compiledExtensions: compiled,
            unsafeMembers: members.filter(isUnsafe),
            sha256: Self.hexDigest(of: data)
        )
    }

    /// Throws unless this wheel is safe to unpack and pure Python.
    ///
    /// Order matters: purity is reported before path safety, because a compiled
    /// wheel is the case a caller will actually hit and the one with a real
    /// explanation attached.
    public func validate() throws {
        guard isPurePython else {
            throw PythonPackageError.notPurePython(
                package: name.distribution,
                filename: "\(name.distribution)-\(name.version)…whl",
                members: compiledExtensions.isEmpty
                    // Tags say compiled, contents do not: name the tags, since
                    // that is the only evidence there is.
                    ? ["(no compiled members, but the wheel is tagged "
                        + "\(name.abiTags.joined(separator: "."))-\(name.platformTags.joined(separator: "."))"
                        + " rather than none-any)"]
                    : compiledExtensions
            )
        }
        if let unsafeMember = unsafeMembers.first {
            throw PythonPackageError.unsafeArchiveMember(unsafeMember)
        }
    }

    /// Throws unless the bytes hash to `expected`.
    ///
    /// Constant-time comparison is not needed — this is an integrity check
    /// against a published value, not a secret — but a case-insensitive one is,
    /// because indexes are inconsistent about hex case.
    public func verify(sha256 expected: String) throws {
        let wanted = expected.lowercased()
        guard wanted == sha256 else {
            throw PythonPackageError.digestMismatch(expected: wanted, actual: sha256)
        }
    }

    static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Zip slip, plus the two variants that are not slashes.
    static func isUnsafe(_ member: String) -> Bool {
        if member.hasPrefix("/") || member.hasPrefix("\\") { return true }
        if member.contains("\\") { return true }  // a Windows separator is never a legitimate member name
        if member.contains("\0") { return true }
        // A drive letter — `C:/…` — is absolute on the platform that wrote it.
        if member.count > 1, member.dropFirst().hasPrefix(":") { return true }
        return member.split(separator: "/").contains("..")
    }
}

// MARK: - A minimal ZIP central-directory reader

/// Just enough ZIP to list what is in a wheel.
///
/// Reading only the central directory is the whole design. Decompression is left
/// to Python's own `zipfile`, which is already in the bundled standard library
/// and has had thirty years of adversarial input — writing a second inflate
/// implementation here would add risk and subtract nothing. What *cannot* be
/// left to Python is the decision of whether to unpack at all, because that has
/// to be answerable before an interpreter exists.
enum ZIPCentralDirectory {

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50

    static func memberNames(in data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else {
            throw PythonPackageError.malformedArchive(reason: "too short to contain a ZIP directory")
        }

        // The end-of-central-directory record is last, except for a trailing
        // comment of up to 65535 bytes — so it is found by scanning backwards,
        // not by seeking to a fixed offset.
        let searchLimit = max(0, bytes.count - 22 - 65535)
        var eocd: Int?
        var index = bytes.count - 22
        while index >= searchLimit {
            if readUInt32(bytes, at: index) == endOfCentralDirectorySignature {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else {
            throw PythonPackageError.malformedArchive(reason: "no end-of-central-directory record")
        }

        let entryCount = Int(readUInt16(bytes, at: eocd + 10))
        let directorySize = Int(readUInt32(bytes, at: eocd + 12))
        let directoryOffset = Int(readUInt32(bytes, at: eocd + 16))

        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF
            || (eocd >= 20 && readUInt32(bytes, at: eocd - 20) == zip64LocatorSignature)
        {
            // Deliberately refused rather than half-implemented. A ZIP64 wheel
            // means more than 65,535 files or more than 4 GB, which no
            // pure-Python package is; meeting one means something else is wrong,
            // and guessing at the offsets would hide it.
            throw PythonPackageError.malformedArchive(
                reason: "ZIP64 archives are not supported. A pure-Python wheel this large is not "
                    + "something this installer should be unpacking."
            )
        }

        guard directoryOffset >= 0, directoryOffset + directorySize <= bytes.count else {
            throw PythonPackageError.malformedArchive(reason: "the central directory lies outside the file")
        }

        var names: [String] = []
        names.reserveCapacity(entryCount)
        var cursor = directoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count else {
                throw PythonPackageError.malformedArchive(reason: "a central directory header is truncated")
            }
            guard readUInt32(bytes, at: cursor) == centralFileHeaderSignature else {
                throw PythonPackageError.malformedArchive(
                    reason: "expected a central file header at offset \(cursor)")
            }
            let nameLength = Int(readUInt16(bytes, at: cursor + 28))
            let extraLength = Int(readUInt16(bytes, at: cursor + 30))
            let commentLength = Int(readUInt16(bytes, at: cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else {
                throw PythonPackageError.malformedArchive(reason: "a member name is truncated")
            }
            // Members are UTF-8 when bit 11 of the general-purpose flags is set
            // and CP437 otherwise; every wheel-producing tool sets it. Decoding
            // as UTF-8 with replacement is right for the purpose here — a name
            // that does not decode is not a name any of these checks would pass.
            names.append(
                String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self))
            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return names
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
