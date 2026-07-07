# Audiobook Timing File Format (v2)

Strobe's audiobook sync pairs a DRM-free audio file with a companion timing file that maps every spoken word to its onset time. The app only consumes this file; generating it happens on another device (see Generation below).

A ready-to-import example pair lives in [`examples/gettysburg-address/`](examples/gettysburg-address/).

## Schema

Hierarchical segment-and-word JSON, version 2:

```json
{
  "version": 2,
  "audio": "the-hobbit.mp3",
  "language": "en",
  "segments": [
    {
      "s": 0.42,
      "words": [
        { "w": "In",   "s": 0.42 },
        { "w": "a",    "s": 0.55 },
        { "w": "hole", "s": 0.61 }
      ]
    },
    {
      "s": 0.94,
      "words": [
        { "w": "in",     "s": 0.94 },
        { "w": "the",    "s": 1.02 },
        { "w": "ground", "s": 1.10 }
      ]
    }
  ]
}
```

Field semantics:

- `version` (required): must be `2`. Other versions are rejected.
- `audio` (optional, informational): the audio file the timings were generated against. The app pairs by user selection, not by this field.
- `language` (optional): BCP-47 language tag.
- `segments` (required, non-empty): one entry per sentence (or paragraph). Each segment:
  - `s` (required): segment onset in seconds. Equals the first word's `s`.
  - `words` (required, non-empty): the display tokens in order. Each word:
    - `w` (required): the token exactly as it should appear on screen. The app never re-tokenizes; punctuation, casing, and diacritics ship as-is. Must be non-empty and must not contain newline characters.
    - `s` (required): spoken onset in seconds from the start of the audio.

Segments are the recovery mechanism: the app re-anchors the displayed word at every segment boundary, so a locally wrong word time (dropped word, narrator ad-lib) self-corrects by the end of its segment instead of drifting for the rest of the book. Prefer sentence-level segments; they re-anchor more often than paragraphs.

## Validation the app enforces on import

- `version == 2`, otherwise rejected as unsupported.
- Well-formed JSON with the shapes above, otherwise rejected as malformed.
- All word starts and all segment starts monotonic non-decreasing and non-negative. Equal adjacent timestamps are permitted (the later word wins at that instant).
- The last word's start must be within the audio duration plus 2 seconds, otherwise rejected as mismatched with the audio.
- File size capped at 64 MB.
- The audio must be decodable and not DRM-protected. Protected, corrupt, and unsupported audio produce distinct errors.

## Generation (out of app scope)

Recommended pipeline, in order of accuracy:

1. **Forced alignment** (best when you have the exact book text). Align the known transcript to the audio for accurate word onsets, segment by sentence. Tools: WhisperX (alignment stage plus its segment output), Montreal Forced Aligner, or aeneas (fragment level, good for the segment layer).
2. **Word-level ASR** (when you only have audio). WhisperX or faster-whisper emit segments and word timestamps in one pass. Slightly looser token boundaries than forced alignment.

Both routes emit segments plus per-word start times; a small script serializes them into the schema above.

**Audio caveat:** VBR MP3 seek and time accuracy depend on a valid Xing/VBRI header. For the tightest seek behavior prefer CBR MP3 or m4a/aac.
