import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// What this system's audio encoders will actually accept — sample rates,
/// bitrates and channel layouts — asked of CoreAudio rather than assumed.
///
/// ## Why this exists, and why it is not optional
///
/// `AVAssetWriterInput(mediaType:outputSettings:)` does not *fail* on settings
/// an encoder cannot honour. **It raises an Objective-C exception**, which in
/// Swift is not an error: it cannot be caught, it unwinds nothing, and it takes
/// the host application down with it. Handing a 5.1 source's own channel layout
/// to the AAC encoder is enough to do it —
///
/// ```
/// *** -[AVAssetWriterInput initWithMediaType:outputSettings:sourceFormatHint:]
///     Channel layout is not valid for Format ID 'aac '.
/// ```
///
/// — because AAC does not accept every `kAudioChannelLayoutTag_*` that describes
/// six channels; it accepts the handful its own bitstream can signal, and the
/// tag a WAV or CAF file carries for the same six speakers is frequently not one
/// of them. A library that crashes the app on somebody's concert recording is
/// not a library, so **every value that reaches an output settings dictionary
/// passes through this type first.**
///
/// This is the audio spelling of the rule the still-image path states: ask the
/// system what it can do, per format, at run time. There is no `#available`
/// here and there must never be one — which codecs accept which layouts is not
/// a function of the OS version, and a version check would be a guess wearing a
/// compiler's clothes.
///
/// ## How it asks
///
/// `AudioFormatGetProperty` with
/// `kAudioFormatProperty_AvailableEncodeChannelLayoutTags`,
/// `…AvailableEncodeSampleRates` and `…AvailableEncodeBitRates` — the same
/// tables the encoder itself consults, so the answer is authoritative rather
/// than a proxy for one.
public enum AudioEncodeSupport {

    // MARK: - Channel layouts

    /// The channel layout to hand the encoder for a source with this layout, or
    /// `nil` when this format cannot encode this channel count here at all.
    ///
    /// Three steps, and the middle one is the point: the source's own tag is
    /// preferred where the encoder accepts it, and **translated** to an
    /// equivalent the encoder does accept where it does not. Only when neither
    /// works is the answer `nil`, which ``ChannelPolicy`` turns into a stereo
    /// downmix rather than a crash.
    static func channelLayout(
        forSource source: Data?,
        formatID: AudioFormatID,
        channels: Int
    ) -> Data? {
        guard channels > 2 else { return nil }   // Mono and stereo need no layout.
        let available = availableChannelLayoutTags(formatID: formatID, channels: channels)
        guard !available.isEmpty else { return nil }

        if let tag = tag(of: source), available.contains(tag) {
            return layoutData(tag: tag)
        }
        // The encoder's own first choice for this channel count. For AAC at six
        // channels that is the AAC 5.1 arrangement, which is what an MPEG-4
        // file should hold anyway.
        guard let fallback = available.first(where: {
            AudioChannelLayoutTag_GetNumberOfChannels($0) == UInt32(channels)
        }) else { return nil }
        return layoutData(tag: fallback)
    }

    /// The layout tags this format can encode at this channel count.
    static func availableChannelLayoutTags(
        formatID: AudioFormatID,
        channels: Int
    ) -> [AudioChannelLayoutTag] {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = formatID
        asbd.mChannelsPerFrame = UInt32(max(1, channels))

        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd, &size
        ) == noErr, size > 0 else { return [] }

        var tags = [AudioChannelLayoutTag](
            repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size
        )
        guard AudioFormatGetProperty(
            kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd, &size, &tags
        ) == noErr else { return [] }
        return tags
    }

    /// The tag naming a layout, deriving one where the layout describes its
    /// channels individually instead.
    ///
    /// A layout can say what it is in three ways: a tag, a bitmap of speakers,
    /// or a list of channel descriptions. Only the first is a tag already, and
    /// reading `mChannelLayoutTag` without checking is how the other two get
    /// mistaken for the tag `0` — which is `kAudioChannelLayoutTag_UseChannelDescriptions`
    /// and is a valid-looking answer that means nothing.
    static func tag(of layout: Data?) -> AudioChannelLayoutTag? {
        guard let layout, layout.count >= MemoryLayout<AudioChannelLayout>.size else { return nil }
        let declared = layout.withUnsafeBytes { raw in
            raw.loadUnaligned(
                fromByteOffset: MemoryLayout.offset(of: \AudioChannelLayout.mChannelLayoutTag)!,
                as: AudioChannelLayoutTag.self
            )
        }
        if declared != kAudioChannelLayoutTag_UseChannelDescriptions,
           declared != kAudioChannelLayoutTag_UseChannelBitmap {
            return declared
        }

        var derived: AudioChannelLayoutTag = 0
        var size = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            AudioFormatGetProperty(
                kAudioFormatProperty_TagForChannelLayout,
                UInt32(raw.count), raw.baseAddress!, &size, &derived
            )
        }
        return status == noErr ? derived : nil
    }

    /// A tag-only `AudioChannelLayout`, as the bytes `AVChannelLayoutKey` wants.
    static func layoutData(tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    // MARK: - Sample rates

    /// The rate this format will encode at, at or below `requested`.
    ///
    /// Never *above*: the no-upsample rule holds even when the encoder would be
    /// happier at a higher rate. `nil` means the requested rate is below
    /// anything this format can do, which is a refusal rather than a licence to
    /// resample upward — see ``AudioTranscoder``.
    static func sampleRate(atOrBelow requested: Double, formatID: AudioFormatID) -> Double? {
        let ranges = availableSampleRates(formatID: formatID)
        // No table means the format imposes no restriction worth enforcing —
        // linear PCM, notably.
        guard !ranges.isEmpty else { return requested }

        if ranges.contains(where: { requested >= $0.mMinimum && requested <= $0.mMaximum }) {
            return requested
        }
        // The highest rate the format offers that is still at or below what was
        // asked for.
        let below = ranges.map(\.mMaximum).filter { $0 <= requested }.max()
        return below
    }

    static func availableSampleRates(formatID: AudioFormatID) -> [AudioValueRange] {
        var identifier = formatID
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeSampleRates,
            UInt32(MemoryLayout<AudioFormatID>.size), &identifier, &size
        ) == noErr, size > 0 else { return [] }

        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioFormatGetProperty(
            kAudioFormatProperty_AvailableEncodeSampleRates,
            UInt32(MemoryLayout<AudioFormatID>.size), &identifier, &size, &ranges
        ) == noErr else { return [] }
        // A zero-width range at 0 is how some formats say "anything".
        return ranges.filter { $0.mMaximum > 0 }
    }

    // MARK: - Bitrates

    /// `requested`, clamped into what this format will accept.
    ///
    /// Clamped rather than refused: a bitrate is a request for a *quality*, and
    /// the nearest one the encoder offers is what the caller meant. It is
    /// clamped before ``LossySourceRule`` sees it, so the rule compares against
    /// the number the encoder will really be given rather than the one that was
    /// typed.
    static func bitrate(nearest requested: Int, formatID: AudioFormatID) -> Int {
        let ranges = availableBitrates(formatID: formatID)
        guard !ranges.isEmpty else { return requested }
        if ranges.contains(where: {
            Double(requested) >= $0.mMinimum && Double(requested) <= $0.mMaximum
        }) {
            return requested
        }
        let lowest = ranges.map(\.mMinimum).min() ?? Double(requested)
        let highest = ranges.map(\.mMaximum).max() ?? Double(requested)
        return Int(min(max(Double(requested), lowest), highest))
    }

    static func availableBitrates(formatID: AudioFormatID) -> [AudioValueRange] {
        var identifier = formatID
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeBitRates,
            UInt32(MemoryLayout<AudioFormatID>.size), &identifier, &size
        ) == noErr, size > 0 else { return [] }

        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioFormatGetProperty(
            kAudioFormatProperty_AvailableEncodeBitRates,
            UInt32(MemoryLayout<AudioFormatID>.size), &identifier, &size, &ranges
        ) == noErr else { return [] }
        return ranges.filter { $0.mMaximum > 0 }
    }

    // MARK: - Diagnostics

    /// What this system's audio encoders accept, as one string for a bug report.
    ///
    /// The audio half of the package's capability reporting: "the transcode
    /// refused a 5.1 file" and "this encoder has no layout for six channels"
    /// look identical from the outside without it.
    public static func diagnosticReport() -> String {
        var lines: [String] = ["Lathe audio encode support (runtime-probed):"]
        for codec in AudioCodec.allCases {
            let formatID = codec.formatID
            let rates = availableSampleRates(formatID: formatID)
                .map { $0.mMinimum == $0.mMaximum
                    ? "\(Int($0.mMinimum))"
                    : "\(Int($0.mMinimum))–\(Int($0.mMaximum))"
                }
                .joined(separator: ", ")
            let surround = availableChannelLayoutTags(formatID: formatID, channels: 6).count
            lines.append("  \(codec.codecName): rates [\(rates.isEmpty ? "unrestricted" : rates)], "
                + "\(surround) accepted 5.1 layout(s)")
        }
        return lines.joined(separator: "\n")
    }
}

extension AudioCodec {
    /// The CoreAudio format ID this codec encodes to.
    var formatID: AudioFormatID {
        switch self {
        case .aac: kAudioFormatMPEG4AAC
        case .appleLossless: kAudioFormatAppleLossless
        }
    }
}
