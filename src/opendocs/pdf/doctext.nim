## Document-level text: pages, lines, blocks, exact search.
##
## `extractText` yields one run per shown string in content order.
## This module groups runs into lines (shared baseline, or shared
## column for vertical WMode 1 runs), lines into blocks (small gaps
## plus matching indent; vertical columns join right to left), and
## searches the result with plain substring matching from the stdlib.
##
## Deliberate limits: content order is kept (no column reordering),
## block boxes span run origins (not ink extents), and case folding is
## ASCII only. Two-column pages may merge same-baseline runs into one
## line; centered or hanging-indented lines may split blocks. Sheet
## tables read horizontal lines only; vertical tables extract as
## column lines but are not detected as tables.

import std/algorithm
import std/strutils
import ./types
import ./docmodel
import ./text

export text

const maxExcerptLen* = 120 ## rune-safe cap for TextHit.excerpt

type
  TextLine* = object
    text*: string
    x*: float64 ## first run origin (runs are x-sorted)
    y*: float64
    size*: float64 ## largest run size on the line
    runs*: seq[TextRun]
    starts*: seq[int] ## byte offset of each run inside `text`
    idx*: int ## position in the page line list (for table use)

  TextBlock* = object
    text*: string ## lines joined with "\n"
    x*: float64 ## minimum run origin (not an ink box)
    y*: float64
    w*: float64 ## origin span; 0 for single-run blocks
    h*: float64
    lines*: seq[TextLine]

  PageText* = object
    index*: int
    width*: float64 ## MediaBox size in points
    height*: float64
    runs*: seq[TextRun]
    lines*: seq[TextLine]
    blocks*: seq[TextBlock]
    text*: string ## blocks joined with "\n\n"

  DocumentText* = object
    version*: string
    pages*: seq[PageText]

  TextHit* = object
    page*: int
    line*: int
    col*: int ## byte offset of the match inside the line
    x*: float64 ## owning run origin (no per-glyph widths)
    y*: float64
    size*: float64
    fontName*: string
    excerpt*: string

proc pageCount*(d: DocumentText): int {.inline.} = d.pages.len

proc text*(d: DocumentText): string =
  ## Whole document as plain text, pages joined with form feed.
  for i, p in d.pages:
    if i > 0:
      result.add('\x0C')
    result.add(p.text)

proc joinRuns*(runs: seq[TextRun],
    wordTol: float64): tuple[text: string, starts: seq[int]] =
  ## Line text from x-sorted runs plus each run's byte offset in it.
  ## A space goes in only when the gap past the previous run's advance
  ## reaches wordTol of an em: kerns and tracked single glyphs join
  ## directly, real word spaces survive. Shared with sheet tables,
  ## which rebuild cell text from runs.
  result = ("", @[])
  for i, r in runs:
    if i > 0:
      let prev = runs[i - 1]
      let gap = r.x - (prev.x + prev.w)
      if gap >= wordTol * max(prev.size, r.size):
        result.text.add(' ')
    result.starts.add(result.text.len)
    result.text.add(r.text)

proc groupLines*(runs: seq[TextRun], lineTol = 0.5,
    wordTol = 0.15): seq[TextLine] =
  ## Runs sharing a baseline become one x-sorted line. Vertical runs
  ## sharing a column band become one y-descending line (reading order
  ## top to bottom); their text concatenates directly. A run joins
  ## the open line while the cross-axis distance stays within lineTol
  ## times the larger font size.
  result = @[]
  for r in runs:
    if result.len > 0:
      let line = addr result[^1]
      let sameKind =
        (line.runs[0].vert and r.vert) or
        (not line.runs[0].vert and not r.vert)
      if sameKind:
        let d =
          if r.vert: abs(r.x - line.x)
          else: abs(r.y - line.y)
        if d <= lineTol * max(r.size, line.size):
          line.runs.add(r)
          line.size = max(line.size, r.size)
          continue
    result.add(TextLine(text: "", x: r.x, y: r.y, size: r.size,
      runs: @[r], idx: result.len))
  for line in result.mitems:
    if line.runs[0].vert:
      line.runs.sort(proc(a, b: TextRun): int = cmp(b.y, a.y))
      line.x = line.runs[0].x
      line.y = line.runs[0].y
      line.text = ""
      line.starts = @[]
      for r in line.runs:
        line.starts.add(line.text.len)
        line.text.add(r.text)
    else:
      line.runs.sort(proc(a, b: TextRun): int = cmp(a.x, b.x))
      line.x = line.runs[0].x
      line.y = line.runs[0].y
      let joined = joinRuns(line.runs, wordTol)
      line.text = joined.text
      line.starts = joined.starts

proc groupBlocks*(lines: seq[TextLine], blockGap = 1.5): seq[TextBlock] =
  ## Consecutive lines become one block while the gap stays within
  ## blockGap times the previous size and the indent matches within
  ## twice that size. Vertical lines advance right to left: they join
  ## while the column step left stays within the gap and the tops
  ## align. Mixed orientations always split.
  result = @[]
  for line in lines:
    if result.len > 0:
      let blk = addr result[^1]
      let prev = blk.lines[^1]
      let pv = prev.runs[0].vert
      let lv = line.runs[0].vert
      if pv and lv:
        if prev.x - line.x >= 0.0 and
            prev.x - line.x <= blockGap * prev.size and
            abs(line.y - prev.y) <= 2.0 * prev.size:
          blk.lines.add(line)
          continue
      elif not pv and not lv:
        if abs(prev.y - line.y) <= blockGap * prev.size and
            abs(line.x - prev.x) <= 2.0 * prev.size:
          blk.lines.add(line)
          continue
    result.add(TextBlock(text: "", x: line.x, y: line.y, w: 0.0, h: 0.0,
      lines: @[line]))
  for blk in result.mitems:
    var parts: seq[string] = @[]
    var minX = blk.lines[0].x
    var minY = blk.lines[0].y
    var maxX = minX
    var maxY = minY
    for line in blk.lines:
      parts.add(line.text)
      for r in line.runs:
        minX = min(minX, r.x)
        minY = min(minY, r.y)
        maxX = max(maxX, r.x)
        maxY = max(maxY, r.y)
    blk.text = parts.join("\n")
    blk.x = minX
    blk.y = minY
    blk.w = maxX - minX
    blk.h = maxY - minY

proc buildPage(d: var PdfDoc, index: int, box: PageBox): PageText =
  let runs = d.extractText(index)
  let lines = groupLines(runs)
  let blocks = groupBlocks(lines)
  var parts: seq[string] = @[]
  for blk in blocks:
    parts.add(blk.text)
  PageText(index: index, width: box.width, height: box.height,
    runs: runs, lines: lines, blocks: blocks, text: parts.join("\n\n"))

proc pageText*(d: var PdfDoc, index: int): PageText =
  ## Runs, lines, blocks and joined text for one page. Geometry comes
  ## from the page tree; a missing box fails like `pageBoxes` does.
  let runs = d.extractText(index)
  var box = PageBox(index: index, width: 0.0, height: 0.0)
  for b in d.pageBoxes():
    if b.index == index:
      box = b
  let lines = groupLines(runs)
  let blocks = groupBlocks(lines)
  var parts: seq[string] = @[]
  for blk in blocks:
    parts.add(blk.text)
  PageText(index: index, width: box.width, height: box.height,
    runs: runs, lines: lines, blocks: blocks, text: parts.join("\n\n"))

proc extractDocumentText*(d: var PdfDoc, version = ""): DocumentText =
  ## Whole-document text model, page order preserved. Page boxes are
  ## read once, so large documents stay linear.
  let boxes = d.pageBoxes()
  result = DocumentText(version: version, pages: @[])
  for b in boxes:
    result.pages.add(d.buildPage(b.index, b))

proc runeCut(s: string, limit: int): string =
  if s.len <= limit:
    return s
  var n = limit
  while n > 0 and (byte(s[n]) and 0xC0) == 0x80:
    dec n
  s[0 ..< n] & "…"

proc searchText*(doc: DocumentText, query: string,
    caseSensitive = false): seq[TextHit] =
  ## Exact substring search over line texts. Empty queries match
  ## nothing. Each hit points at its line plus the owning run for
  ## coordinates; the excerpt is the full line capped at
  ## `maxExcerptLen` runes.
  result = @[]
  if query.len == 0:
    return
  let needle = if caseSensitive: query else: query.toLowerAscii()
  for p in doc.pages:
    for li, line in p.lines:
      let hay = if caseSensitive: line.text else: line.text.toLowerAscii()
      var start = 0
      while true:
        let at = find(hay, needle, start)
        if at < 0:
          break
        var run = line.runs[^1]
        for i, r in line.runs:
          if at < line.starts[i] + r.text.len:
            run = r
            break
        result.add(TextHit(page: p.index, line: li, col: at, x: run.x,
          y: run.y, size: run.size, fontName: run.fontName,
          excerpt: runeCut(line.text, maxExcerptLen)))
        start = at + max(needle.len, 1)
