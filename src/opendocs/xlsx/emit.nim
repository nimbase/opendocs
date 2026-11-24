## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Writer-side XML emitter backed by `buffalo` reusable buffers.
##
## Behavioral oracle: excelize `templates.go` blank-part shapes (see
## `xlsx/write` for the part list). Clean-room: shapes observed, bytes
## authored here. Divergences from excelize are documented in
## `xlsx/write`, not here.
##
## Why buffalo: sheet XML is the largest single allocation in a save
## (1M rows). A `PooledBuffer[byte]` reused across parts avoids repeated
## allocator trips: `initPool` once per save, `clear` per part, geometric
## growth only on overflow, flat after steady state. Callers that need a
## scratch value (cell refs, serials) use a stack `StaticBuffer` in a
## `buffaloScope` at the call site; this module never allocates except
## through the pool.
##
## Why not `withBorrow`: the borrow DSL forbids escaping the buffer, but
## an emitter must hand bytes to the zip packer after the scope ends. So
## this module uses the pool directly (`appendMany`, `toString`) and
## leaves lifetime with the owning `XlsxEmit` value. The explicit
## copy-out (`toBytes`/`toString`) is the sanctioned escape hatch.

type
  XlsxEmit* = object
    ## Reusable XML builder. Owns one `PooledBuffer[byte]`; call `clear`
    ## to reuse for the next part.
    pool*: PooledBuffer[byte]

proc initXlsxEmit*(cap = 65536): XlsxEmit =
  ## Fresh emitter with a pre-sized backing (one sheet row is ~100B,
  ## so 64KB holds ~600 rows before growth).
  XlsxEmit(pool: initPool(byte, cap))

proc clear*(e: var XlsxEmit) =
  ## Reuse for the next part. Keeps the backing (no free).
  e.pool.clear()

proc len*(e: XlsxEmit): int =
  e.pool.len

proc addRaw*(e: var XlsxEmit, s: string) =
  ## Unescaped bytes (tags, attributes already escaped by callers).
  if s.len > 0:
    e.pool.appendMany(s)

proc addByte*(e: var XlsxEmit, b: byte) =
  e.pool.add(b)

proc decl*(e: var XlsxEmit) =
  e.addRaw("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")

func xlsxAttr*(name, val: string): string =
  " " & name & "=\"" & xmlAttrEscape(val) & "\""

func xlsxOptAttr*(name, val: string): string =
  if val == "": "" else: xlsxAttr(name, val)

proc openTag*(e: var XlsxEmit, tag: string, attrs = "") =
  e.addRaw("<" & tag & attrs & ">")

proc closeTag*(e: var XlsxEmit, tag: string) =
  e.addRaw("</" & tag & ">")

proc emptyTag*(e: var XlsxEmit, tag: string, attrs = "") =
  e.addRaw("<" & tag & attrs & "/>")

proc textNode*(e: var XlsxEmit, s: string) =
  e.addRaw(xmlEscape(s))

proc elemNode*(e: var XlsxEmit, tag, body: string, attrs = "") =
  e.openTag(tag, attrs)
  e.textNode(body)
  e.closeTag(tag)

proc toBytes*(e: XlsxEmit): seq[byte] =
  ## Owned copy of the used prefix. The emitter stays usable.
  result = newSeq[byte](e.pool.len)
  if e.pool.len > 0:
    copyMem(addr result[0], unsafeAddr e.pool.data[0], e.pool.len)

proc toString*(e: XlsxEmit): string =
  ## Owned string copy via the buffalo escape hatch.
  e.pool.toString()

proc needsPreserve*(s: string): bool =
  ## Whether `<t>`/`<v>` needs `xml:space="preserve"` (excelize
  ## `trimCellValue` parity): leading/trailing tab/LF/CR/space.
  if s.len == 0: return false
  let first = s[0]
  let last = s[^1]
  first in {'\t', '\n', '\r', ' '} or last in {'\t', '\n', '\r', ' '}
