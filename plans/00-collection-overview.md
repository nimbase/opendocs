# opendocs — collection overview (quick plan)

Scope decisions (locked): **read + write together** for every format,
**per-format APIs only** (no unified DOM), **full `.doc` write** included.

## Formats

| Format | Container | Read strategy | Write difficulty |
|---|---|---|---|
| `txt` | raw bytes | encoding detect (UTF-8/16, ANSI) | trivial |
| `rtf` | raw text | control-word tokenizer (`{\rtf`, `\par`, `\b`, font/colortbl) | medium |
| `docx` | ZIP + OOXML | custom zip over zlib + `std/xmlparser` | medium (minimal valid package) |
| `odt` | ZIP + ODF | custom zip over zlib + `content.xml`, `META-INF/manifest.xml` | medium |
| `xlsx` | ZIP + OOXML | custom zip + `sharedStrings.xml`, sheet XML | medium |
| `pptx` | ZIP + OOXML | custom zip + slide XML | medium |
| `doc` | OLE2 CFB + MS-DOC binary | custom CFB reader + FIB + piece table | very hard, esp. write |

## Key dependency fact (`clue dump zlib` → status-im/nim-zlib 0.2.0)

`zlib` is **raw deflate/gzip only** (`deflateInit2`/`inflateInit2` with
`Z_RAW_DEFLATE`, `crc32`, vendored C sources). It has **no ZIP archive I/O**.
So `docx/odt/xlsx/pptx` need a new `zip` module on top of `zlib_api`:
local file headers, central directory, stored + deflated methods, CRC32 verify.
XML comes from stdlib (`xmlparser`/`xmltree`/`parsexml`) — no extra dep.
`opendocs.nimble` gains `requires "zlib >= 0.2.0"`.

## Module layout (`src/opendocs/`)

```
opendocs.nim        # re-exports per-format modules only
  zip.nim           # ZIP reader/writer on zlib_api (shared plumbing, not a DOM)
  ole2.nim          # CFB reader/writer (FAT/DIFAT/MiniFAT, directory entries)
  xmlutil.nim       # thin xmltree helpers
  txt.nim           # readText / writeText
  rtf.nim           # readRtf / writeRtf
  docx.nim          # readDocx / writeDocx
  doc.nim           # readDoc / writeDoc (uses ole2)
  odt.nim           # readOdt / writeOdt
  xlsx.nim          # readXlsx / writeXlsx
  pptx.nim          # readPptx / writePptx
```

Each module owns its types (`DocxDocument`, `RtfDocument`, …). `zip`/`ole2`/
`xmlutil` are shared plumbing, not a document model.

## References (local, `nimbase/references/`)

- `docx-rs/` — Rust docx reader/writer. Relevant parts: `docx-core/src/`
  (`documents/`, `reader/`, `types/`, `xml/`, `xml_builder/`, `zipper/`) and
  `fixtures/` (~78 fixture dirs) + `hello.docx`/`hello.json`. Use for OOXML
  part layout and writer minimal-package shape.
- `msdoc/` (Go, `TalentFormula/msdoc`, MIT) — `.doc` reader **and writer**.
  Relevant parts: `ole2/` (sector/directory reader+writer), `fib/`
  (File Information Block), piece-table text reassembly, `writer/`
  (document creation), `cmd/msdocdump/`. Primary reference for the `.doc`
  write path, which has almost no other open implementation.
- Evaluated but not cloned: `HyunjoJung/rwml` (best-documented Rust `.doc`
  read internals: FIB navigation, lid→codepage pieces, CHPX/PAPX), `SuiltaPico/
  office_oxide` (multi-format, CFB+FIB→piece table), `abemedia/go-cfb`
  (minimal pure-Go CFB reader/writer).

## Phases (each phase = read + write + round-trip test)

1. Found: `zlib` dep, `zip.nim` (list/extract/create, round-trip), `xmlutil`,
   `tests/fixtures/` corpus. Zip-slip guard + decompression cap (follow
   zlib's `GZIP_DECOMPRESS_LIMIT` ~20MB pattern, configurable).
2. `txt` + `rtf` (no zip/CFB — fastest win, proves per-format API shape).
3. `docx` (proves zip+XML write path; template for xlsx/pptx/odt).
4. `odt`, then `xlsx`, then `pptx` (reuse `zip.nim`).
5. `doc` (OLE2 + FIB; read, then write — see `01-doc-docx-indepth.md`).
6. Hardening: malformed-input tests per format, large files, docs.

## Testing

`tests/t_<format>.nim` per format: `write → read → compare` round-trips plus
checked-in minimal fixtures (Word/LibreOffice-generated + docx-rs fixtures
where license-compatible). Runner: `clue test`.

## Risks

- `.doc` write is 2–4× the cost of `docx` (CFB allocator + FIB/piece-table
  writer); timebox via minimal-valid-file goal (Word/LibreOffice opens it),
  not byte-fidelity with Word output.
- OOXML fidelity: target "clean minimal valid file", not pixel-perfect.
- Encrypted/obfuscated inputs: detect and return errors, never silent garbage.
