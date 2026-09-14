import Foundation

/// The still-image formats Lathe knows about.
///
/// Membership in this enum says nothing about whether the running system can
/// *encode* a format — ask ``EncodeSupport`` for that. The two are separate on
/// purpose: Lathe never branches on OS version, it asks the system what it can
/// encode and degrades per-format, and that only works if the vocabulary of
/// formats is larger than the set the system happens to support today.
public enum ImageFormat: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case heic
    /// HEIF image sequence — the animated sibling of HEIC.
    case heics
    case avif
    case jpeg
    case png
    case tiff
    case gif
    case webp
    case jpegXL
    case jp2
    case pdf

    /// The canonical Uniform Type Identifier ImageIO uses.
    public var typeIdentifier: String {
        switch self {
        case .heic: "public.heic"
        case .heics: "public.heics"
        // AVIF has no `UTTypeAVIF` / `kUTTypeAVIF` constant in any Apple SDK, so
        // the raw string is the only way to name it. See `EncodeSupport`.
        case .avif: "public.avif"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .webp: "org.webmproject.webp"
        case .jpegXL: "public.jpeg-xl"
        case .jp2: "public.jpeg-2000"
        case .pdf: "com.adobe.pdf"
        }
    }

    /// Other identifiers that have been observed to mean the same format.
    ///
    /// Belt and braces: ImageIO's list is not contractually stable, and a rename
    /// upstream should degrade a capability probe, not silently disable a
    /// format we can actually write.
    public var alternateTypeIdentifiers: [String] {
        switch self {
        // `public.heif` is advertised by ImageIO and does not actually encode,
        // so it is listed after the canonical spelling and never wins the match.
        case .heic: ["public.heif", "public.heic-image"]
        case .heics: ["public.heif-sequence"]
        case .avif: ["public.avci"]
        // Deliberately no alias for JPEG: `public.jpeg-2000` is a *different*
        // format, and its encode availability varies by platform. Aliasing it
        // here would make the capability probe lie.
        case .jpegXL: ["public.jxl"]
        case .jp2: ["public.jp2"]
        case .webp: ["com.google.webp"]
        default: []
        }
    }

    /// Every identifier that should be accepted as "this format".
    public var allTypeIdentifiers: [String] {
        [typeIdentifier] + alternateTypeIdentifiers
    }

    public var preferredFilenameExtension: String {
        switch self {
        case .heic: "heic"
        case .heics: "heics"
        case .avif: "avif"
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .gif: "gif"
        case .webp: "webp"
        case .jpegXL: "jxl"
        case .jp2: "jp2"
        case .pdf: "pdf"
        }
    }

    public var description: String {
        switch self {
        case .heic: "HEIC"
        case .heics: "HEICS"
        case .avif: "AVIF"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .webp: "WebP"
        case .jpegXL: "JPEG XL"
        case .jp2: "JPEG 2000"
        case .pdf: "PDF"
        }
    }

    /// Whether the format stores pixels lossily by default.
    public var isLossyByDefault: Bool {
        switch self {
        case .jpeg, .heic, .heics, .avif, .jpegXL, .jp2: true
        case .png, .tiff, .gif, .webp, .pdf: false
        }
    }

    /// Whether the format can carry an alpha channel.
    ///
    /// Load-bearing when recompressing images inside a PDF: an image and its
    /// `/SMask` are one unit, and you must **never JPEG an alpha channel**.
    public var supportsAlpha: Bool {
        switch self {
        case .jpeg: false
        case .heic, .heics, .avif, .png, .tiff, .gif, .webp, .jpegXL, .jp2, .pdf: true
        }
    }

    /// Whether PDF permits this as an embedded image filter.
    ///
    /// **PDF has no HEIC/WebP/AVIF/JXL.** The legal filters are DCTDecode,
    /// JPXDecode, Flate, LZW, RunLength, CCITTFax and JBIG2 — so of the formats
    /// here, only JPEG (DCTDecode) and JPEG 2000 (JPXDecode) may be embedded
    /// as-is. JPEG is very nearly always the right one of the two.
    public var isLegalInsidePDF: Bool {
        self == .jpeg || self == .jp2
    }

    /// Whether the format carries more than one frame.
    public var isAnimatable: Bool {
        switch self {
        case .gif, .webp, .heics, .avif, .png: true
        case .jpeg, .heic, .tiff, .jpegXL, .jp2, .pdf: false
        }
    }
}

extension ImageFormat {
    /// The format a filename extension names, or `nil` if the extension is not
    /// one Lathe writes.
    ///
    /// Case-insensitive, and tolerant of the spellings that mean the same thing
    /// in the wild (`jpg`/`jpeg`, `tif`/`tiff`, `j2k`/`jp2`). A leading dot is
    /// accepted so `URL.pathExtension` and a user-typed `".png"` both work.
    ///
    /// This deliberately answers *what the caller asked for*, not *what the
    /// system can write*. Ask ``EncodeSupport`` for the second question — a
    /// recognised extension whose encoder is missing must fail as
    /// ``LatheError/encodeUnavailable(format:)``, which is a different problem
    /// with a different remedy from an extension nobody recognises.
    public static func named(byFilenameExtension fileExtension: String) -> ImageFormat? {
        switch fileExtension.lowercased().drop(while: { $0 == "." }) {
        case "heic", "heif": .heic
        case "heics", "heifs": .heics
        case "avif", "avifs": .avif
        case "jpg", "jpeg", "jpe": .jpeg
        case "png": .png
        case "tif", "tiff": .tiff
        case "gif": .gif
        case "webp": .webp
        case "jxl": .jpegXL
        case "jp2", "j2k", "jpf", "jpx", "jpm": .jp2
        case "pdf": .pdf
        default: nil
        }
    }
}
