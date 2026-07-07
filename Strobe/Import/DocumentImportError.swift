import Foundation

/// Errors that can occur during document import.
enum DocumentImportError: Error, Equatable, LocalizedError {
    case unsupportedFileType
    case epubExtractionFailed
    case epubDRMProtected
    case pdfLoadFailed
    case pdfPasswordProtected
    case noReadableText
    case unsupportedTimingVersion
    case malformedTimings
    case nonMonotonicTimings
    case timingsExceedAudio
    case audioProtected
    case audioCorrupt
    case audioUnsupported
    case audioCopyFailed
    case audiobookPairRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Unsupported file type. Import a PDF or EPUB file."
        case .epubExtractionFailed:
            return "Could not read this EPUB file. It may be corrupted or DRM-protected."
        case .epubDRMProtected:
            return "This EPUB is DRM-protected and can't be imported. Only DRM-free books are supported."
        case .pdfLoadFailed:
            return "Could not open this PDF file. It may be corrupted."
        case .pdfPasswordProtected:
            return "This PDF is password-protected. Remove the password and try again."
        case .noReadableText:
            return "Could not extract text from this document. It may be image-only."
        case .unsupportedTimingVersion:
            return "This timing file uses an unsupported format version. Strobe supports version 2."
        case .malformedTimings:
            return "Could not read this timing file. It may be corrupted or not a Strobe timing file."
        case .nonMonotonicTimings:
            return "This timing file has out-of-order or negative timestamps and can't be used."
        case .timingsExceedAudio:
            return "The timing file is longer than the audio. Check that both files belong to the same book."
        case .audioProtected:
            return "This audio file is DRM-protected and can't be imported. Only DRM-free audio is supported."
        case .audioCorrupt:
            return "Could not decode this audio file. It may be corrupted."
        case .audioUnsupported:
            return "Unsupported audio format. Import an MP3, M4A, or other standard audio file."
        case .audioCopyFailed:
            return "Could not copy the audio into the library. Check available disk space and try again."
        case .audiobookPairRequired:
            return "Select exactly one audio file and one timing file together."
        }
    }
}
