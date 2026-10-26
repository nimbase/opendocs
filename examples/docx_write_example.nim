## Showcase of the opendocs DOCX builder API.
##
## Run from the package root:
##   clue build examples/docx_write_example.nim --out:/tmp/docx_write_example
##   /tmp/docx_write_example [output.docx]

import std/[os, strutils]
import opendocs/docx

proc main() =
  var doc = newDocx("Builder demo", "opendocs")

  var title = newParagraph("Hello, DOCX", "Heading1")
  title.addText(" (builder API)")
  doc.addParagraph(title)

  var body = newParagraph()
  body.addText("This document was created with the high-level builder API.")
  body.addRun(newRun(" Bold run", bold = true, sizePt = 12))
  doc.addParagraph(body)

  var t = newTable(2, 2)
  t.cell(0, 0).blocks.add Block(kind: bkParagraph,
    paragraph: newParagraph("row 0, col 0"))
  t.cell(0, 1).blocks.add Block(kind: bkParagraph,
    paragraph: newParagraph("row 0, col 1"))
  t.cell(1, 0).blocks.add Block(kind: bkParagraph,
    paragraph: newParagraph("row 1, col 0"))
  t.cell(1, 1).blocks.add Block(kind: bkParagraph,
    paragraph: newParagraph("row 1, col 1"))
  doc.addTable(t)

  let path =
    if paramCount() >= 1: paramStr(1)
    else: "docx_write_example.docx"
  writeDocx(doc, path)
  echo "wrote ", path

when isMainModule:
  main()
