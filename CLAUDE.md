# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

**Do NOT run `xcodebuild` commands.** The user builds and tests separately in Xcode.

The project targets iOS 17.0+ / macOS 14.0+ and uses the `Strobe` scheme. CI runs on GitHub Actions with `macos-26`, testing both an iOS simulator (any available iPhone, selected dynamically) and native macOS.

### Testing
Tests use the **Swift Testing** framework (not XCTest):
- `@Test` for test functions, `#expect` for assertions
- Test file: `StrobeTests/StrobeTests.swift`

## Architecture

Strobe is an RSVP (Rapid Serial Visual Presentation) speed reader for iOS and macOS. Users import PDFs/EPUBs/plain-text files or paste text, then read word-by-word with configurable timing.

### Data Flow
```
PDF/EPUB/Text → DocumentImportPipeline → Extractor → TextCleaner → Tokenizer → [String]
                                                                                    ↓
                                              Document (SwiftData) ← WordStorage (blob)
                                                                                    ↓
                                                        RSVPEngine → WordView (display)
```

### Key Layers

**Import Pipeline** (`Import/`): `DocumentImportPipeline` detects file type via UTType, routes to `EPUBTextExtractor`, `PDFTextExtractor`, or a plain-text reader, then cleans and tokenizes. EPUB extraction uses `ZIPExtractor` → OPF parsing → DRM check (`META-INF/encryption.xml` vs. spine) → HTML stripping. Long phases check `Task.checkCancellation()` so the import overlay's Cancel works. Returns `ImportResult` with words, chapters, source type, and title.

**Tokenizer** (`Engine/Tokenizer.swift`): Whitespace-based splitting with special handling for:
- Soft hyphen removal, non-breaking hyphen normalization
- Line-break hyphen merging (with compound-word detection)
- CJK text: detected by Unicode range, segmented via `NLTokenizer`, punctuation attached to preceding word
- Mixed-script text: character-by-character buffering switches between Latin and CJK

**RSVPEngine** (`Engine/RSVPEngine.swift`): `@Observable` class driving timer-based word advancement. Supports smart timing (duration scales with word length), sentence pauses (multiplier at sentence-ending punctuation across Latin, CJK, and Arabic scripts), and complexity timing (per-word duration modulation based on cognitive complexity scores).

**WordComplexityAnalyzer** (`Engine/WordComplexityAnalyzer.swift`): Scores each word's cognitive complexity (0.0–1.0) using NLTagger lexical class, named entity recognition, word frequency (built-in common word list), character composition, and word length. Scores are computed at import time and stored as a parallel `[Float]` blob via `ComplexityStorage`.

**WordView** (`Views/WordView.swift`): Renders words with Optimal Recognition Point (ORP) highlighting — anchor letter at ~1/3 position in red. Uses single `AttributedString` to preserve Arabic cursive shaping (color-only highlight, no bold) and correct glyph order. CJK short words use centered anchor.

**Persistence**: SwiftData `Document` model stores words externally as newline-delimited UTF-8 blob (`WordStorage`) and per-word complexity scores as raw Float binary (`ComplexityStorage`). In-memory caches (`cachedWords`, `cachedComplexity`) avoid repeated deserialization.

### Xcode Project
Uses `PBXFileSystemSynchronizedRootGroup` — Xcode auto-mirrors the on-disk folder structure. Moving files on disk is sufficient; no `project.pbxproj` edits needed.

## Folder Structure
```
Strobe/
├── App/          App entry point, SwiftData container bootstrap
├── Engine/       RSVPEngine (playback), Tokenizer (word splitting), WordComplexityAnalyzer
├── Import/       DocumentImportPipeline, extractors, TextCleaner, ZIPExtractor
├── Models/       SwiftData models (Document, Chapter, WordStorage, ComplexityStorage)
├── Views/        All SwiftUI views
├── Theme/        StrobeTheme (colors, typography, hex parser)
├── Utilities/    HapticManager, ReaderFont
├── Fonts/        Custom font files (Fraunces, Inter, JetBrainsMono, PT*, SpaceGrotesk)
```

## Conventions

- **State management**: `@Observable` (not ObservableObject/Combine), `@Bindable`, `@AppStorage`
- **Concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- **Logging**: `os.Logger` with subsystem/category
- **Theme**: Dark mode only, background `0x050505`, accent "Strobe Red" `#FF3B30`
- **Typography**: Fraunces (`titleFont`) for headings and for large display numerals in Settings cards (WPM, text size — `titleFont(size: 32)` in `textPrimary`); body text and captions use `bodyFont`. Keep sibling numerals styled identically.
- **Error types**: `DocumentImportError` enum (`unsupportedFileType`, `epubExtractionFailed`, `epubDRMProtected`, `pdfLoadFailed`, `pdfPasswordProtected`, `noReadableText`)
- **Settings keys**: `defaultWPM`, `fontSize`, `smartTimingEnabled`, `sentencePauseEnabled`, `smartTimingPercentPerLetter`, `sentencePauseMultiplier`, `complexityTimingEnabled`, `complexityIntensity`, `holdToReadEnabled`, `readerFontSelection`, `textCleaningLevel` — all registered in `ReaderSettings.Keys` (plus app flags `hasSeenTutorial`, `didCompactLegacyWordStorage`); never use raw key strings
- **Navigation**: value-based (`NavigationLink(value:)` + `navigationDestination` in `ContentView`, `ReaderRoute` for chapter entries) — eager `destination:` links would decode word blobs for every visible row. `ReaderView` loads word blobs asynchronously in `.task`, never in `init`.
- **Platform conditionals**: `#if os(iOS)` / `#if os(macOS)` for UIKit/AppKit imports, haptics, presentation modifiers, and hint text. Engine, import pipeline, and models are fully cross-platform.
- **macOS keyboard shortcuts**: Space (play/pause), Left/Right arrows (scrub), Escape (dismiss reader) — via `.onKeyPress`, also works on iPad with hardware keyboard
- **macOS haptics**: `HapticManager` is no-op on macOS (all methods are empty stubs)

<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
