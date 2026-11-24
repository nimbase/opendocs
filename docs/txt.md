# TXT Reader and Writer

Implementation: `src/opendocs/txt.nim`, imported directly (`import
opendocs/txt`). No ZIP, no XML, no new dependencies (stdlib +
`buffalo`, both already required).

## Reading

```nim
import opendocs/txt

let doc = readTextFile("notes.txt")
echo doc.encoding # encUtf8, encUtf16LE, ...
echo doc.lineEnding # leLF, leCRLF, leCR, leMixed, leNone
echo doc.text # decoded UTF-8, LF-normalized

let same = readTextMapped("notes.txt") # zero-copy mmap scan
let d2 = decodeBytes(bytes)
let d3 = decodeText("literal")
```

- `TxtDoc(text, encoding, lineEnding, hasBom)` — text is decoded
  UTF-8 with LF endings; the metadata reproduces the source on write.
- Detection order: BOM, NUL-stride UTF-16 test, strict UTF-8
  validation, then Latin-1 / Windows-1252 (see header for the exact
  rules). Everything malformed raises `TxtError`; bare invalid UTF-8
  without a BOM is single-byte text by design (locked decision), while
  invalid UTF-8 *after* a BOM fails (the BOM commits to its codec).
- `readTextMapped(path)` scans the mapping via `buffalo/memView`
  (no `readBytes` copy); one pass produces the owned string.
- `eachLine(path)` streams lines (`splitlines` semantics, all three
  break kinds) in O(longest line) memory; consume fully (the mapping
  closes at exhaustion). `readTextLines(path)` collects them.

## Writing

```nim
writeTextFile("out.txt", doc) # faithful rewrite under doc metadata
writeTextFile("out.txt", "a\nb", TxtWriteOpts(
  encoding: encUtf16LE, bom: true, lineEnding: leCRLF))
writeTextMapped("big.txt", text) # single copy through a mapping
```

- `TxtWriteOpts(encoding, bom, lineEnding)` — defaults UTF-8, no BOM,
  LF. `writeTextFile(path, doc)` uses the doc's own encoding/BOM, and
  its detected breaks (`leMixed`/`leNone` write as LF).
- `encodeDoc(text, opts) / encodeDoc(doc): seq[byte]`.
- `writeTextMapped` encodes once into a staging pool and copies into
  a size-known mapping (`copyToMemFile`); removes any prior file
  first (mappings cannot resize). Plain, non-atomic writes throughout
  (locked decision): crashes truncate, like `writeFile`.
- Unrepresentable codepoints (`€` to Latin-1, emoji to 1252) and
  invalid UTF-8 input fail loudly with `TxtError`.

## Utilities

- Breaks: `detectLineEnding`, `normalizeEndings`, `lines(doc)`,
  `lineCount`, `trimTrailingSpace`, `ensureTrailingNewline`.
- Content: `charCount` (runes), `wordCount` (unicode whitespace),
  `byteCount` (UTF-8 length of decoded text).
- Bytes: `isValidUtf8`, `detectBom`, `decodeLatin1`,
  `decodeWindows1252` (the five undefined bytes fail loudly),
  `countUtf16Units`, `truncateUtf16Units` (rune-boundary cuts, same
  pattern as the xlsx writer).

See `tests/t_txt.nim` (34/34, inline byte fixtures only — no checked-in
binaries, no tools, fully hermetic).
