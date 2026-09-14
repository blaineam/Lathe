import Foundation

/// What can go wrong acquiring and installing a Python package.
///
/// Separate from ``PythonError`` because these are failures of *the user's
/// intent* — a package that does not exist, a download that does not match its
/// hash, a wheel that cannot work on this platform — rather than failures of the
/// interpreter. A caller shows most of these to a person; it shows none of
/// ``PythonError`` to a person.
public enum PythonPackageError: Error, Sendable, Equatable {

    /// The filename is not a PEP 427 wheel name.
    case malformedWheelName(String, reason: String)

    /// The archive is not a readable ZIP, or uses a feature this reader does not
    /// implement.
    case malformedArchive(reason: String)

    /// The download does not hash to what the index said it would.
    ///
    /// Carries both digests, because the interesting case is not "corrupt" — it
    /// is a proxy, a captive portal, or a cache returning something else
    /// entirely, and seeing the two values is what makes that obvious.
    case digestMismatch(expected: String, actual: String)

    /// The index published no hash for this file at all.
    ///
    /// Treated as a failure rather than a warning. An unverified download
    /// executed as code is the whole of the risk this installer exists to bound.
    case digestMissing(filename: String)

    /// The wheel contains compiled code, so it cannot be installed this way —
    /// ever, on iOS, by anyone.
    ///
    /// Not a limitation of this installer. iOS does not permit a process to
    /// produce or load a dynamic library it did not ship with: a downloaded
    /// `.so` cannot be signed, cannot be mapped executable, and will not import.
    /// Refusing at install time with the offending members named is far better
    /// than an `ImportError` on `_lxml` three screens later.
    case notPurePython(package: String, filename: String, members: [String])

    /// No pure-Python wheel exists for this project at this version.
    case noPureWheelAvailable(package: String, version: String, candidates: [String])

    /// The index has no such project, or no such version of it.
    case notFoundInIndex(package: String, version: String?)

    /// The index answered, but not with something this code understands.
    case indexUnreadable(package: String, reason: String)

    /// The transport failed.
    case transportFailed(reason: String)

    /// A ZIP member would extract outside the destination directory.
    ///
    /// "Zip slip". Checked here rather than left to the extractor, and checked
    /// in Swift rather than in the Python that does the extracting, so the check
    /// exists whether or not an interpreter is running.
    case unsafeArchiveMember(String)

    /// Asked to remove or update something that is not installed.
    case notInstalled(package: String)

    /// The install directory could not be created or written.
    case storeUnwritable(path: String, reason: String)
}

extension PythonPackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .malformedWheelName(name, reason):
            "\(name) is not a valid wheel filename: \(reason)"
        case let .malformedArchive(reason):
            "The wheel is not a readable archive: \(reason)"
        case let .digestMismatch(expected, actual):
            "Hash mismatch. The index published sha256:\(expected) and the bytes hash to "
                + "sha256:\(actual). Nothing was installed."
        case let .digestMissing(filename):
            "\(filename) is published without a sha256 hash, so it cannot be verified. Refusing to install it."
        case let .notPurePython(package, filename, members):
            """
            \(package) cannot be installed: \(filename) contains compiled extension modules, \
            and this installer only handles pure-Python wheels.

            This is not a missing feature. iOS cannot load a dynamic library that was not part of \
            the signed application, so a compiled extension downloaded at run time can never be \
            imported — on any device, by any installer.

            Compiled members: \(members.prefix(8).joined(separator: ", "))\
            \(members.count > 8 ? " (and \(members.count - 8) more)" : "")
            """
        case let .noPureWheelAvailable(package, version, candidates):
            "\(package) \(version) publishes no pure-Python wheel. Available files: "
                + (candidates.isEmpty ? "none" : candidates.joined(separator: ", "))
        case let .notFoundInIndex(package, version):
            version.map { "\(package) \($0) is not in the index." } ?? "\(package) is not in the index."
        case let .indexUnreadable(package, reason):
            "The index response for \(package) could not be read: \(reason)"
        case let .transportFailed(reason):
            "The download failed: \(reason)"
        case let .unsafeArchiveMember(name):
            "The wheel contains a member that would be written outside the install directory: \(name)"
        case let .notInstalled(package):
            "\(package) is not installed."
        case let .storeUnwritable(path, reason):
            "The package directory \(path) is not usable: \(reason)"
        }
    }
}
