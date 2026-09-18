## Sheet extraction: each page as a list of classified rows.
##
## A row is one text block plus a `BlockKind` guess: headings are
## runs of visibly larger type, list items match bullet or ordered
## markers, captions start with Figure/Table-style labels, anything
## near body size is a paragraph, and the rest (footers, folios,
## tiny print) is `bkOther`.
##
## Tables are detected separately by `detectTables`: column edges that
## repeat across lines seed row bands, and single-edge lines between
## bands attach as wrapped cell text. A table needs at least two row
## bands and two columns; single-column runs and lone header lines
## stay ordinary rows. Headers are only split out when the first band
## is visibly larger than the rest, otherwise every band is data.
## Table member lines leave `rows` and appear only in `tables`.
##
## The body size is the per-page mode of line sizes, so a title-only
## page reads its title as body. Rules are deliberately shallow and
## documented. Limits: whitespace grid only (ruling lines never reach
## `TextRun`s), no spanning cells (a wide cell fills its left column),
## no column-flow reordering, and dense tables whose row pitch drops
## under `attachTol` sizes may glue wraps to the wrong row.

import std/algorithm
import std/sets
import std/strutils
import std/tables
import ./docmodel
import ./doctext

export doctext

type
  BlockKind* = enum
    bkHeading, bkParagraph, bkListItem, bkCaption, bkOther

  SheetRow* = object
    kind*: BlockKind
    text*: string
    x*: float64
    y*: float64
    w*: float64
    h*: float64
    size*: float64 ## largest line size in the row

  PdfTable* = object
    page*: int
    x*: float64
    y*: float64 ## top (maximum baseline)
    w*: float64
    h*: float64
    headers*: seq[string] ## first band, only when visibly larger
    rows*: seq[seq[string]] ## data bands, one cell per column

  SheetPage* = object
    index*: int
    width*: float64
    height*: float64
    rows*: seq[SheetRow]
    tables*: seq[PdfTable]

  Sheet* = object
    version*: string
    pages*: seq[SheetPage]

proc pageCount*(s: Sheet): int {.inline.} = s.pages.len

proc bodySize*(lines: seq[TextLine]): float64 =
  ## Most common line size (exact float mode, ties keep the first).
  ## Empty input yields 0, which classifies everything as `bkOther`.
  var counts = initTable[float64, int]()
  var best = 0.0
  var bestN = 0
  for line in lines:
    let n = counts.getOrDefault(line.size, 0) + 1
    counts[line.size] = n
    if n > bestN:
      bestN = n
      best = line.size
  best

proc isListItem(t: string): bool =
  # U+2022, hyphen, asterisk, en/em dash, U+2023, plus U+F0B7: the
  # Private Use bullet that Symbol/Differences-mapped Word lists
  # decode to.
  for b in ["\xE2\x80\xA2 ", "- ", "* ", "\xE2\x80\x93 ", "\xE2\x80\x94 ",
      "\xE2\x80\xA3 ", "\xEF\x82\xB7 "]:
    if t.startsWith(b):
      return true
  var i = 0
  while i < t.len and t[i] in Digits:
    inc i
  if i > 0 and i + 1 < t.len and t[i] in {'.', ')'} and t[i+1] == ' ':
    return true
  if t.len >= 3 and t[0] in Letters and t[1] == '.' and t[2] == ' ':
    return true
  false

proc isCaption(t: string): bool =
  let s = t.toLowerAscii()
  for p in ["figure ", "figure:", "fig. ", "fig ", "table ", "table:",
      "listing ", "equation "]:
    if s.startsWith(p):
      return true
  false

proc rowSize(blk: TextBlock): float64 =
  for line in blk.lines:
    result = max(result, line.size)

proc classifyBlock*(blk: TextBlock, body: float64): BlockKind =
  ## Kind of one block against the page body size. Pattern rules
  ## (list, caption) win over size rules (heading, paragraph, other).
  let t = blk.text.strip()
  if t.len == 0 or body <= 0.0:
    return bkOther
  let size = rowSize(blk)
  if isListItem(t):
    bkListItem
  elif isCaption(t) and size <= body * 1.1:
    bkCaption
  elif size >= body * 1.25:
    bkHeading
  elif size >= body * 0.8:
    bkParagraph
  else:
    bkOther

proc detectTables*(lines: seq[TextLine], pageIndex = 0,
    edgeTol = 2.0, minEdgeSupport = 3, gutterTol = 1.5, bandTol = 0.5,
    attachTol = 1.6, regionGapTol = 5.0, wordTol = 0.15):
    tuple[tables: seq[PdfTable], consumed: HashSet[int]] =
  ## Whitespace-grid tables over page lines. Run left-edges that
  ## repeat across lines become column edges; lines hitting two or
  ## more edges seed row bands; single-edge lines between bands attach
  ## as wrapped cell text. Returns the tables plus the consumed line
  ## indices, so callers can keep rows and tables disjoint.
  ##
  ## The gutter rule is what keeps body text out: an edge only counts
  ## a supporting line when the run starts the line or follows a gap
  ## of at least `gutterTol` ems. Tracked and justified body runs sit
  ## nearly adjacent, so their coincidental alignments never qualify.
  result = (tables: @[], consumed: initHashSet[int]())
  if lines.len == 0:
    return
  # Column edges: cluster run starts, keep well-supported ones.
  var starts: seq[tuple[x: float64, line: int]] = @[]
  for li, line in lines:
    for r in line.runs:
      starts.add((r.x, li))
  starts.sort(proc(a, b: tuple[x: float64, line: int]): int =
    cmp(a.x, b.x))
  var edgeX: seq[float64] = @[]
  var edgeN: seq[int] = @[]
  for s in starts:
    if edgeX.len > 0 and abs(s.x - edgeX[^1]) <= edgeTol:
      edgeX[^1] = (edgeX[^1] * float64(edgeN[^1]) + s.x) /
        float64(edgeN[^1] + 1)
      inc edgeN[^1]
    else:
      edgeX.add(s.x)
      edgeN.add(1)
  # Gutter-backed support per edge, plus gutter-backed hits.
  var edgeOK: seq[HashSet[int]] = newSeq[HashSet[int]](edgeX.len)
  var hits: seq[HashSet[int]] = newSeq[HashSet[int]](lines.len)
  for i in 0 ..< edgeX.len:
    edgeOK[i] = initHashSet[int]()
  for li in 0 ..< lines.len:
    hits[li] = initHashSet[int]()
  for li, line in lines:
    for ri, r in line.runs:
      var ei = -1
      for k in 0 ..< edgeX.len:
        if abs(r.x - edgeX[k]) <= edgeTol:
          ei = k
          break
      if ei < 0:
        continue
      var gutter = ri == 0
      if not gutter:
        let prev = line.runs[ri - 1]
        gutter = r.x - (prev.x + prev.w) >= gutterTol * r.size
      if gutter:
        edgeOK[ei].incl(li)
        hits[li].incl(ei)
  var edges: seq[float64] = @[]
  for i in 0 ..< edgeX.len:
    if edgeOK[i].len >= minEdgeSupport:
      edges.add(edgeX[i])
  if edges.len < 2:
    return
  # Hits reference qualified edges: remap cluster index to edge index.
  var edgeOf = newSeq[int](edgeX.len)
  for k in 0 ..< edgeX.len:
    edgeOf[k] = -1
    for ei in 0 ..< edges.len:
      if abs(edgeX[k] - edges[ei]) <= edgeTol:
        edgeOf[k] = ei
        break
  var qhits: seq[HashSet[int]] = newSeq[HashSet[int]](lines.len)
  for li in 0 ..< lines.len:
    qhits[li] = initHashSet[int]()
    for k in hits[li]:
      if edgeOf[k] >= 0:
        qhits[li].incl(edgeOf[k])
  hits = move(qhits)
  var seedSet = initHashSet[int]()
  var seeds: seq[int] = @[]
  for li in 0 ..< lines.len:
    if hits[li].len >= 2:
      seeds.add(li)
      seedSet.incl(li)
  # Row bands from seed lines, top (maximum y) first.
  seeds.sort(proc(a, b: int): int = cmp(lines[b].y, lines[a].y))
  type Band = object
    y: float64
    size: float64
    lines: seq[int]
    edgeSet: HashSet[int]
  var bands: seq[Band] = @[]
  for li in seeds:
    if bands.len > 0:
      let top = addr bands[^1]
      if abs(lines[li].y - top.y) <=
          bandTol * max(lines[li].size, top.size):
        top.lines.add(li)
        for e in hits[li]:
          top.edgeSet.incl(e)
        top.size = max(top.size, lines[li].size)
        continue
    var es = initHashSet[int]()
    for e in hits[li]:
      es.incl(e)
    bands.add(Band(y: lines[li].y, size: lines[li].size,
      lines: @[li], edgeSet: es))
  for b in bands.mitems:
    var sum = 0.0
    for li in b.lines:
      sum += lines[li].y
    b.y = sum / float64(b.lines.len)
  # Regions: split bands on large vertical gaps.
  var regions: seq[seq[int]] = @[]
  var cur: seq[int] = @[]
  for bi in 0 ..< bands.len:
    if cur.len > 0:
      let prev = bands[cur[^1]]
      if prev.y - bands[bi].y >
          regionGapTol * max(prev.size, bands[bi].size):
        regions.add(cur)
        cur = @[]
    cur.add(bi)
  if cur.len > 0:
    regions.add(cur)
  # One grid per region.
  for regIn in regions:
    if regIn.len < 2:
      continue
    var seen = initHashSet[int]()
    var cols: seq[int] = @[]
    for bi in regIn:
      for e in bands[bi].edgeSet:
        if e notin seen:
          seen.incl(e)
          cols.add(e)
    cols.sort(proc(a, b: int): int = cmp(edges[a], edges[b]))
    if cols.len < 2:
      continue
    var colSet = initHashSet[int]()
    for c in cols:
      colSet.incl(c)
    var bandLines: seq[seq[int]] = @[]
    for bi in regIn:
      bandLines.add(bands[bi].lines)
    for li in 0 ..< lines.len:
      if li in seedSet or hits[li].len != 1:
        continue
      var best = -1
      var bestD = Inf
      for ri, bi in regIn:
        let dd = abs(lines[li].y - bands[bi].y)
        if dd < bestD:
          bestD = dd
          best = ri
      if best < 0:
        continue
      let bb = bands[regIn[best]]
      var ok = bestD <= attachTol * max(lines[li].size, bb.size)
      if ok:
        for e in hits[li]:
          if e notin colSet:
            ok = false
            break
      if ok:
        bandLines[best].add(li)
    # Endpoint bands must touch the first column: justified body
    # lines above or below a table can seed false bands, and those
    # never start at the table's left edge.
    var lo = 0
    var hi = regIn.len - 1
    while lo <= hi and cols[0] notin bands[regIn[lo]].edgeSet:
      inc lo
    while hi >= lo and cols[0] notin bands[regIn[hi]].edgeSet:
      dec hi
    if hi - lo + 1 < 2:
      continue
    var reg: seq[int] = @[]
    var kept: seq[seq[int]] = @[]
    for ri in lo .. hi:
      reg.add(regIn[ri])
      kept.add(bandLines[ri])
    bandLines = move(kept)
    seen.clear()
    cols.setLen(0)
    for bi in reg:
      for e in bands[bi].edgeSet:
        if e notin seen:
          seen.incl(e)
          cols.add(e)
    cols.sort(proc(a, b: int): int = cmp(edges[a], edges[b]))
    colSet.clear()
    for c in cols:
      colSet.incl(c)
    var grid: seq[seq[string]] = @[]
    var sizes: seq[float64] = @[]
    var minX = Inf
    var maxEx = -Inf
    var topY = -Inf
    var botY = Inf
    for ri, bi in reg:
      let bb = bands[bi]
      var cell: seq[seq[TextRun]] = newSeq[seq[TextRun]](cols.len)
      for li in bandLines[ri]:
        for r in lines[li].runs:
          var ci = -1
          for k in 0 ..< cols.len:
            if edges[cols[k]] <= r.x + edgeTol:
              ci = k
          if ci < 0:
            ci = 0
          cell[ci].add(r)
          minX = min(minX, r.x)
          maxEx = max(maxEx, r.x + r.w)
          topY = max(topY, r.y)
          botY = min(botY, r.y)
      var row: seq[string] = @[]
      for k in 0 ..< cols.len:
        var rs = cell[k]
        rs.sort(proc(a, b: TextRun): int =
          if a.y != b.y: cmp(b.y, a.y) else: cmp(a.x, b.x))
        var parts: seq[string] = @[]
        var sub: seq[TextRun] = @[]
        for r in rs:
          if sub.len > 0 and abs(r.y - sub[^1].y) >
              bandTol * max(r.size, sub[^1].size):
            parts.add(joinRuns(sub, wordTol).text)
            sub = @[]
          sub.add(r)
        if sub.len > 0:
          parts.add(joinRuns(sub, wordTol).text)
        row.add(parts.join("\n").strip())
      grid.add(row)
      sizes.add(bb.size)
      for li in bandLines[ri]:
        result.consumed.incl(li)
    var ss = sizes
    ss.sort()
    var tab = PdfTable(page: pageIndex, x: minX, y: topY,
      w: maxEx - minX, h: topY - botY, headers: @[], rows: @[])
    if sizes[0] >= 1.15 * ss[ss.len div 2]:
      tab.headers = grid[0]
      tab.rows = grid[1 .. ^1]
    else:
      tab.rows = grid
    result.tables.add(tab)

proc sheetPage*(d: var PdfDoc, index: int): SheetPage =
  ## One page as classified rows in content order, plus detected
  ## tables. Table member lines leave `rows`.
  let p = d.pageText(index)
  let body = bodySize(p.lines)
  let found = detectTables(p.lines, p.index)
  result = SheetPage(index: p.index, width: p.width, height: p.height,
    rows: @[], tables: found.tables)
  for blk in p.blocks:
    var kept: seq[TextLine] = @[]
    for line in blk.lines:
      if line.idx notin found.consumed:
        kept.add(line)
    if kept.len == 0:
      continue
    var parts: seq[string] = @[]
    var minX = kept[0].x
    var minY = kept[0].y
    var maxX = minX
    var maxY = minY
    var size = 0.0
    for line in kept:
      parts.add(line.text)
      size = max(size, line.size)
      for r in line.runs:
        minX = min(minX, r.x)
        minY = min(minY, r.y)
        maxX = max(maxX, r.x)
        maxY = max(maxY, r.y)
    result.rows.add(SheetRow(kind: classifyBlock(
      TextBlock(text: parts.join("\n"), lines: kept), body),
      text: parts.join("\n"), x: minX, y: minY, w: maxX - minX,
      h: maxY - minY, size: size))

proc extractSheet*(d: var PdfDoc, version = ""): Sheet =
  ## Whole document as pages of classified rows.
  let n = d.pageCount()
  result = Sheet(version: version, pages: @[])
  for i in 0 ..< n:
    result.pages.add(d.sheetPage(i))
