# doc / docx — indepth plan

Per-format APIs (`DocDocument`, `DocxDocument`), read + write together,
`zlib` (status-im/nim-zlib, raw deflate + `crc32`) for all ZIP work.
Do `docx` first — it proves the zip+XML write path that `doc` later reuses
only as pattern, and unblocks odt/xlsx/pptx.

## A. docx (OOXML in ZIP) — first

Reference: `nimbase/references/docx-rs`, esp. `docx-core/src/zipper/`
(package I/O), `reader/`, `xml_builder/`, `documents/` and `fixtures/`.

### Parts to support

`[Content_Types].xml`, `_rels/.rels`, `word/document.xml`,
`word/styles.xml`, `word/_rels/document.xml.rels`, numbering (`word/
numbering.xml`), optional `word/media/*` (preserve via rel-id, no render).

### Read path

1. `zip.open(path)` → entry table from central directory (own code on
   `zlib_api`: `inflateInit2(Z_RAW_DEFLATE)` for deflated, passthrough for
   stored, `crc32` verify, zip-slip guard, size cap).
2. Extract `word/document.xml`; `xmlparser.parseXml`; walk
   `w:document/w:body`: `w:p` (`w:pStyle`, `w:jc`), `w:r` (`w:rPr`: b/i/
   sz/color), `w:t` (honor `xml:space="preserve"`), `w:tbl` (`w:tr`/`w:tc`,
   `gridSpan`/`vMerge`), `w:hyperlink`, `w:drawing` (keep rel-id, skip).
3. Load `styles.xml` + `numbering.xml` best-effort (headings, list labels);
   preserve IDs so write round-trips.
4. Return `DocxDocument` (paragraph/run/table seqs + style table).

### Write path

1. Serialize `DocxDocument` → `document.xml` (escape text; emit
   `w:p/w:r/w:t`, tables). Mirror docx-rs `xml_builder` output shape.
2. Synthesize `[Content_Types].xml` + `.rels` + minimal `styles.xml`
   (Normal + Heading1–6 with `outlineLvl`), `numbering.xml` if needed.
3. `zip.create()`: per entry `crc32`, `deflateInit2(Z_DEFAULT_LEVEL,
   Z_DEFLATED, Z_RAW_DEFLATE, …)` + `deflate(Z_FINISH)`, local headers +
   central directory.
4. Verify: reopen with own reader + open in Word/LibreOffice.

### Edge cases

Stored vs deflated, data-descriptor bit, UTF-8 filenames, duplicate
`document.xml` (zip-confusion — reject), missing styles (default fallback),
tracked-changes (`w:ins` current vs `w:del` old — accept-changes view only).

## B. doc (Word 97–2003, OLE2 CFB + MS-DOC) — second, full write included

Reference: `nimbase/references/msdoc` (Go, MIT): `ole2/` (sector/directory
reader **and writer**), `fib/` (FIB parser + types), piece-table reassembly,
`writer/` (create from scratch), `cmd/msdocdump/` (debug dumps).
Cross-check FIB/piece-table details against `HyunjoJung/rwml` docs
(FIB navigation not hard-coded offsets; lid→codepage: cp1252 Western,
cp949 Korean, etc.) and MS-DOC/MS-CFB specs.

### Read path

1. `ole2.open`: check 512B header magic `D0 CF 11 E0`; DIFAT→FAT chain;
   128B directory entries; resolve `WordDocument`, `Data`, `0Table`/`1Table`
   (pick via FIB `fWhichTblStm`); MiniFAT for small streams. Case-insensitive
   stream lookup.
2. Parse FIB at `WordDocument[0]`: version (`nFib`), `fcClx/lcbClx`,
   `ccpText`, table selectors. Navigate sub-structures, never hard-code
   offsets past the fixed prefix.
3. Parse `Clx` → piece table (`Pcdt/PlcPcd`): per piece `fc` offset,
   `fCompressed` encoding bit, length. Pieces are the **only** correct text
   source — never scan the stream raw.
4. Decode pieces: ANSI (codepage from FIB `lid`) → UTF-8, UTF-16LE → UTF-8;
   map `\r` paragraph marks and `\x07` cell marks; best-effort tables/
   footnotes; rich pass later: CHPX/PAPX via FKP, STSH stylesheet, `PlfLst`/
   `PlfLfo` lists.
5. Detect pre-97 files and XOR-obfuscation/encryption → distinct errors.
   Bounds-check every offset (malformed input returns error, never panics).
6. Return `DocDocument` (paragraphs + preserved FIB/piece metadata for
   write-back).

### Write path (the expensive part)

1. Serialize text → new `WordDocument` stream (UTF-16LE segments), fresh
   `Clx`/piece table, fresh FIB with consistent `fc/lcb` offsets and
   `ccpText`; rebuild `0Table`/`1Table` + `Data`. Follow `msdoc/writer/`
   ordering.
2. `ole2.create`: allocate FAT chain + MiniFAT, directory entries, 512B
   sectors, header (`csectFat/csectDir`, version 3). v4 (4096B) only if
   needed for large files.
3. Verify: own reader round-trip + Word/LibreOffice open. Complex fields
   (fast-saved, embedded OLE, macros): preserve-or-error, never silent
   corruption.

### Order of work

`ole2 read` → `FIB + Clx/piece read` → `doc read` (flat text first, rich
formatting second) → `ole2 write` → `doc write`. Gate each step on
round-trip tests before moving on.

### Fixtures & tests

`tests/fixtures/doc/{empty,styled,table,cjk}.doc`,
`tests/fixtures/docx/*` (subset of docx-rs fixtures): assert text +
paragraph count + style spot-checks + reopen-after-write. Add truncated/
random-bytes malformed tests per format. Target parity method of rwml:
compare flat text vs LibreOffice/POI output on the same fixtures.
