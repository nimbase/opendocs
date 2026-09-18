## Word `.docx` (OOXML WordprocessingML) reader and writer.
##
## High-level API lives here; the model in `docx/types`, the reader
## in `docx/reader`, the writer in `docx/writer`.

import std/[strutils, tables]

# Implementation split: model types, reader, and (later) writer live in
# `docx/` but are included here, so module `docx` keeps one canonical
# home for every symbol and existing importers are unaffected.
include docx/types
include docx/reader
include docx/writer

func effectiveColor*(run: Run, theme: Table[string, string]): string =
  ## Concrete RRGGBB for a run: explicit color wins, else theme color
  ## with shade (toward black) / tint (toward white) blending. "" if none.
  if run.color != "": return run.color
  if run.colorTheme == "" or not theme.hasKey(run.colorTheme): return ""
  let base = theme[run.colorTheme]
  if base.len != 6: return ""
  var rgb: array[3, int]
  try:
    for i in 0 .. 2: rgb[i] = parseHexInt(base[i * 2 .. i * 2 + 1])
  except ValueError: return ""
  if run.colorShade != "":
    try:
      let f = parseHexInt(run.colorShade).float / 255.0
      for i in 0 .. 2: rgb[i] = (rgb[i].float * f + 0.5).int
    except ValueError: discard
  elif run.colorTint != "":
    try:
      let f = parseHexInt(run.colorTint).float / 255.0
      for i in 0 .. 2: rgb[i] = (rgb[i].float * f + 255.0 * (1.0 - f) + 0.5).int
    except ValueError: discard
  result = ""
  for v in rgb: result.add toHex(max(0, min(255, v)), 2)


proc blockParas(b: Block, paras: var seq[string]) =
  ## Accept-changes view: insertions/move destinations kept, deletions
  ## and move sources (run- and body-level) excluded.
  case b.kind
  of bkParagraph:
    var s = ""
    for k in b.paragraph.kids:
      case k.kind
      of pkRun: s.add k.run.text
      of pkFldSimple:
        for r in k.fld.runs: s.add r.text
      of pkIns, pkMoveTo:
        for r in k.rev.runs: s.add r.text
      of pkDel, pkMoveFrom: discard
    paras.add s
  of bkTable:
    for row in b.table.rows:
      for cell in row.cells:
        for cb in cell.blocks: blockParas(cb, paras)
  of bkTextbox:
    for tb in b.textbox.blocks: blockParas(tb, paras)
  of bkSdt:
    for sb in b.sdt.blocks: blockParas(sb, paras)
  of bkIns:
    for ib in b.rev.blocks: blockParas(ib, paras)
  of bkDel: discard

func flatText*(doc: DocxDocument): string =
  ## All paragraph text joined by newlines (tables cell by cell).
  var paras: seq[string]
  for b in doc.blocks: blockParas(b, paras)
  paras.join("\n")

# ------------------------------------------------------------------ getters

func getSections*(doc: DocxDocument): seq[Section] =
  ## All document sections in order.
  doc.sections

func getSection*(doc: DocxDocument, i: int): Section =
  ## Section by index. Raises DocxError when out of range.
  if i < 0 or i >= doc.sections.len:
    raise newException(DocxError, "section index out of range: " & $i)
  doc.sections[i]

func normSectionIdx(doc: DocxDocument, sectionIdx: int): int =
  ## Negative index selects the last section.
  if doc.sections.len == 0:
    raise newException(DocxError, "document has no sections")
  if sectionIdx < 0: doc.sections.len - 1
  elif sectionIdx >= doc.sections.len:
    raise newException(DocxError,
      "section index out of range: " & $sectionIdx)
  else: sectionIdx

func getPageSettings*(doc: DocxDocument, sectionIdx = -1): SectionProps =
  ## Page settings for a section (last section by default).
  doc.sections[normSectionIdx(doc, sectionIdx)].props

func getHeaders*(doc: DocxDocument, sectionIdx = -1,
    kind = ""): seq[Block] =
  ## Header blocks for a section; `kind` filters default/first/even
  ## ("" returns all kinds in order).
  for h in doc.sections[normSectionIdx(doc, sectionIdx)].headers:
    if kind == "" or h.refKind == kind:
      result.add h.blocks

func getFooters*(doc: DocxDocument, sectionIdx = -1,
    kind = ""): seq[Block] =
  ## Footer blocks for a section; `kind` filters default/first/even.
  for f in doc.sections[normSectionIdx(doc, sectionIdx)].footers:
    if kind == "" or f.refKind == kind:
      result.add f.blocks

# ------------------------------------------------------------------- writer

proc writeDocxBytes*(doc: DocxDocument): seq[byte] =
  ## Serialize the document to a complete `.docx` package in memory.
  ## Modeled parts are regenerated (see `docx/writer`); `rawParts`
  ## re-emit byte-exact except where superseded by a regenerated part
  ## (same name, or a per-part `.rels` for a regenerated part).
  let parts = buildPackage(doc)
  var w = newZipWriter()
  var emitted: seq[string]
  for (name, content) in parts:
    w.addFile(name, content)
    emitted.add name
  for name, data in doc.rawParts:
    if name in emitted: continue
    if name == "_rels/.rels": continue # always regenerated (same targets)
    w.addFile(name, data)
  try:
    w.toBytes()
  except ZipError as e:
    raise newException(DocxError, "cannot pack docx: " & e.msg)

proc writeDocx*(doc: DocxDocument, path: string) =
  ## Serialize the document to a `.docx` file on disk.
  let img = writeDocxBytes(doc)
  var f: File
  if not open(f, path, fmWrite):
    raise newException(DocxError, "cannot write file: " & path)
  defer: close(f)
  if img.len > 0 and writeBytes(f, img, 0, img.len) != img.len:
    raise newException(DocxError, "short write: " & path)
