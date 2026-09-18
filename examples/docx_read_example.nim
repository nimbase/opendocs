## Showcase of the opendocs DOCX reader.
##
## Run from the package root:
##   clue build examples/docx_read_example.nim --out:/tmp/docx_read_example
##   /tmp/docx_read_example [optional/path/to/file.docx]
##
## With no argument it walks the vendored fixtures in tests/fixtures/docx/.

import std/[os, strutils, tables]
import opendocs/docx

proc showRun(r: Run, doc: DocxDocument) =
  var tags: seq[string]
  if r.bold: tags.add "bold"
  if r.italic: tags.add "italic"
  if r.underline: tags.add "underline"
  if r.strike: tags.add "strike"
  if r.caps: tags.add "caps"
  if r.smallCaps: tags.add "smallCaps"
  if r.vanish: tags.add "vanish"
  if r.vertAlign != "": tags.add r.vertAlign
  if r.styleId != "": tags.add "style=" & r.styleId
  if r.sizeHalfPts != 0: tags.add "size=" & $(r.sizeHalfPts div 2) & "pt"
  let color = effectiveColor(r, doc.themeColors)
  if color != "": tags.add "color=#" & color
  if r.highlight != "": tags.add "hl=" & r.highlight
  if r.fonts != "": tags.add "font=" & r.fonts
  if r.hyperlinkRid != "":
    tags.add "link=" & doc.hyperlinks.getOrDefault(r.hyperlinkRid, "?")
  if r.drawingRid != "":
    tags.add "drawing=" & r.drawingRid
  if r.footnoteRef >= 0: tags.add "footnote#=" & $r.footnoteRef
  if r.endnoteRef >= 0: tags.add "endnote#=" & $r.endnoteRef
  if r.commentRef >= 0: tags.add "comment#=" & $r.commentRef
  echo "      run [", tags.join(","), "] ", escape(r.text)

proc showPara(p: Paragraph, doc: DocxDocument, indent = "    ") =
  var tags: seq[string]
  if p.styleId != "": tags.add "style=" & p.styleId
  if p.align != "": tags.add "align=" & p.align
  if p.outlineLvl >= 0: tags.add "outline=" & $p.outlineLvl
  if p.numId >= 0: tags.add "list#=" & $p.numId & "/" & $p.numIlvl
  if p.keepNext: tags.add "keepNext"
  if p.pageBreakBefore: tags.add "pageBreakBefore"
  for t in p.tabs: tags.add "tab(" & t.kind & "@" & $t.pos & ")"
  if p.borders.top.style != "": tags.add "borderTop=" & p.borders.top.style
  for b in p.bookmarks: tags.add "bookmark:" & b.name
  echo indent, "para [", tags.join(","), "]"
  for r in p.runs: showRun(r, doc)

proc showBlocks(bs: seq[Block], doc: DocxDocument, indent = "    ") =
  for b in bs:
    case b.kind
    of bkParagraph: showPara(b.paragraph, doc, indent)
    of bkTable:
      let t = b.table
      echo indent, "table style=", t.styleId, " rows=", t.rows.len,
        " grid=", t.grid, " borders=", t.borders.top.style
      for row in t.rows:
        echo indent, "  row h=", row.height, " header=", row.isHeader
        for cell in row.cells:
          echo indent, "    cell span=", cell.gridSpan,
            " vmerge=", cell.vMerge, " valign=", cell.vAlign
          showBlocks(cell.blocks, doc, indent & "      ")
    of bkTextbox:
      echo indent, "textbox:"
      showBlocks(b.textbox.blocks, doc, indent & "  ")
    of bkSdt:
      echo indent, "sdt alias=", b.sdt.alias, " tag=", b.sdt.tag
      showBlocks(b.sdt.blocks, doc, indent & "  ")
    of bkIns, bkDel:
      echo indent, "rev ", b.kind, " id=", b.rev.meta.id,
        " author=", b.rev.meta.author
      showBlocks(b.rev.blocks, doc, indent & "  ")

proc showDoc(path: string) =
  echo "=== ", path.lastPathPart, " ==="
  let doc =
    try: readDocx(path)
    except DocxError as e:
      echo "  DocxError: ", e.msg
      return

  # 1. Plain text + sections/page settings (getters)
  echo "  flat text: ", escape(flatText(doc))
  echo "  sections: ", doc.sections.len
  for i, s in getSections(doc):
    let ps = getPageSettings(doc, i)
    echo "    [", i, "] ", ps.pgW, "x", ps.pgH, " ", ps.orient,
      " type=", ps.sectType, " cols=", ps.colsNum,
      " margins=", ps.marginLeft, "/", ps.marginTop
    for h in s.headers:
      echo "    header(", h.refKind, "):"
      showBlocks(h.blocks, doc, "      ")
    for f in s.footers:
      echo "    footer(", f.refKind, "):"
      showBlocks(f.blocks, doc, "      ")
  echo "  default headers: ", getHeaders(doc).len,
    " default footers: ", getFooters(doc).len

  # 2. Body blocks
  showBlocks(doc.blocks, doc)

  # 3. Numbering + styles + theme
  for numId, levels in doc.numbering:
    for lv in levels:
      echo "  numbering ", numId, "/", lv.ilvl, ": ", lv.format,
        " '", lv.text, "' start=", lv.start
  for id, st in doc.styles:
    echo "  style ", id, " (", st.kind, "): ", st.name,
      " basedOn=", st.basedOn, " qFormat=", st.qFormat
  for name, rgb in doc.themeColors:
    echo "  theme ", name, "=#", rgb

  # 4. Relations: hyperlinks, images, drawings
  for rid, target in doc.hyperlinks:
    echo "  hyperlink ", rid, " -> ", target
  for img in doc.images:
    echo "  image ", img.relId, " ", img.contentType,
      " ", img.data.len, " bytes"
  for rid, d in doc.drawings:
    echo "  drawing ", rid, " ", d.placement, " ", d.cxEmu, "x", d.cyEmu,
      "emu '", d.name, "'"

  # 5. Notes, comments, bookmarks, controls, properties
  for n in doc.footnotes:
    echo "  footnote #", n.id, ":"
    showBlocks(n.blocks, doc, "    ")
  for n in doc.endnotes:
    echo "  endnote #", n.id, ":"
    showBlocks(n.blocks, doc, "    ")
  for c in doc.comments:
    echo "  comment #", c.id, " by ", c.author, " <", c.date, ">:"
    showBlocks(c.blocks, doc, "    ")
  for b in doc.bookmarks:
    echo "  bookmark #", b.id, ": ", b.name
  for s in doc.sdts:
    echo "  sdt alias=", s.alias, " tag=", s.tag
  echo "  core: '", doc.coreProps.title, "' by ", doc.coreProps.author,
    " created ", doc.coreProps.created
  echo "  app: ", doc.appProps.application, " pages=", doc.appProps.pages,
    " words=", doc.appProps.words
  for p in doc.customProps:
    echo "  custom ", p.name, " = ", p.value
  echo "  rawParts preserved: ", doc.rawParts.len
  echo ""

when isMainModule:
  if paramCount() >= 1:
    showDoc(paramStr(1))
  else:
    let dir = currentSourcePath().parentDir() / ".." / "tests" /
      "fixtures" / "docx"
    for f in [
      "hello.docx", "bookmark.docx", "toc0.docx", "nested_table.docx",
      "table_border.docx", "tab_and_break.docx",
      "image_node_docx_floating.docx", "textbox.docx", "numbering.docx",
      "comment.docx", "custom.docx"]:
      showDoc(dir / f)
