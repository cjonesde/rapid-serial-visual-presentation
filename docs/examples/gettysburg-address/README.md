# Example audiobook pair: The Gettysburg Address

A ready-to-import test pair for Strobe's audiobook sync.

- `gettysburg-address.mp3` — LibriVox recording of Abraham Lincoln's Gettysburg Address (public domain), 2:41, 64 kbps CBR MP3. Source: [archive.org/details/gettysburg_address_librivox](https://archive.org/details/gettysburg_address_librivox). LibriVox recordings are dedicated to the public domain.
- `gettysburg-address.timing.json` — companion v2 timing file: 291 words in 25 sentence segments. Generated with `mlx_whisper` (`whisper-medium.en-mlx`, `--word-timestamps True`) and serialized to the schema described in [`../../audiobook-timing-format.md`](../../audiobook-timing-format.md).

## Usage

In the Strobe library: **+ → Import Audiobook**, then select both files together (order does not matter). The preview should show ~291 words / 25 segments opening with "The address at the dedication of the National Cemetery at Gettysburg...".

## Known quirks (intentional, useful for testing)

- The first word onset is at 19.72 s; the recording starts with silence. The display holds the first word until narration begins (documented silence-gap behavior).
- Near 2:25 the ASR misheard "by the people" as "by the law". The token text was corrected by hand; the ASR's slightly imperfect word timings in that region were left as-is, which makes it a natural spot to observe segment re-anchoring holding sync.
- Narrator average is about 108 WPM, so the rate control should display 108 at 1.0x and 162 at 1.5x.
