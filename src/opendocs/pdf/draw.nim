## Vector graphics + color operators (M16d).
##
## Pure operator builders: no document state, just validated strings the
## low-level builder or the high-level `Pdf` appends to a content stream.
## `q`/`Q` balance is the caller's contract; the `Pdf` helpers below
## (in pdf.nim) wrap every path paint in `q...Q`. Circles use four
## Bezier arcs with kappa 0.5522847498. No justification engine, no
## synthetic bold/italic: bold/italic need caller-supplied fonts via
## `loadFont`/`setFont` (documented divergence from plan 13, which
## allowed synthetic emboldening).
##
## Colors are DeviceRGB, DeviceGray or DeviceCMYK floats in 0..1.
## Out-of-range fails loudly; NaN/Inf fails loudly.

import std/strformat
import ./lexer

type
  PdfColorKind* = enum
    ckRgb, ckGray, ckCmyk

  PdfColor* = object
    case kind*: PdfColorKind
    of ckRgb:
      r*, g*, b*: float64
    of ckGray:
      gray*: float64
    of ckCmyk:
      c*, m*, y*, k*: float64

  PathCmdKind* = enum
    pcMove, pcLine, pcCurve, pcClose, pcRect

  PathCmd* = object
    case kind*: PathCmdKind
    of pcMove, pcLine:
      x*, y*: float64
    of pcCurve:
      x1*, y1*, x2*, y2*, x3*, y3*: float64
    of pcRect:
      rx*, ry*, rw*, rh*: float64
    of pcClose:
      discard

  Path* = object
    cmds*: seq[PathCmd]

  FillOpts* = object
    fill*: PdfColor
    hasFill*: bool
    stroke*: PdfColor
    hasStroke*: bool
    lineWidth*: float64 ## <= 0 means unset
    evenOdd*: bool

proc black*(): PdfColor = PdfColor(kind: ckRgb, r: 0.0, g: 0.0, b: 0.0)
proc white*(): PdfColor = PdfColor(kind: ckRgb, r: 1.0, g: 1.0, b: 1.0)
proc rgb*(r, g, b: float64): PdfColor =
  for v in [r, g, b]:
    if v != v or v == Inf or v == -Inf or v < 0.0 or v > 1.0:
      pdfFail("RGB component out of range 0..1")
  PdfColor(kind: ckRgb, r: r, g: g, b: b)
proc gray*(v: float64): PdfColor =
  if v != v or v == Inf or v == -Inf or v < 0.0 or v > 1.0:
    pdfFail("gray component out of range 0..1")
  PdfColor(kind: ckGray, gray: v)
proc cmyk*(c, m, y, k: float64): PdfColor =
  for v in [c, m, y, k]:
    if v != v or v == Inf or v == -Inf or v < 0.0 or v > 1.0:
      pdfFail("CMYK component out of range 0..1")
  PdfColor(kind: ckCmyk, c: c, m: m, y: y, k: k)

proc fillOp*(c: PdfColor): string =
  case c.kind
  of ckRgb: fmt"{c.r} {c.g} {c.b} rg"
  of ckGray: fmt"{c.gray} g"
  of ckCmyk: fmt"{c.c} {c.m} {c.y} {c.k} k"

proc strokeOp*(c: PdfColor): string =
  case c.kind
  of ckRgb: fmt"{c.r} {c.g} {c.b} RG"
  of ckGray: fmt"{c.gray} G"
  of ckCmyk: fmt"{c.c} {c.m} {c.y} {c.k} K"

proc fin(v: float64, what: string): float64 =
  if v != v or v == Inf or v == -Inf:
    pdfFail(what & " is non-finite")
  v

proc moveTo*(p: var Path, x, y: float64) =
  p.cmds.add(PathCmd(kind: pcMove, x: fin(x, "moveTo x"),
    y: fin(y, "moveTo y")))

proc lineTo*(p: var Path, x, y: float64) =
  p.cmds.add(PathCmd(kind: pcLine, x: fin(x, "lineTo x"),
    y: fin(y, "lineTo y")))

proc curveTo*(p: var Path, x1, y1, x2, y2, x3, y3: float64) =
  p.cmds.add(PathCmd(kind: pcCurve, x1: fin(x1, "curveTo x1"),
    y1: fin(y1, "curveTo y1"), x2: fin(x2, "curveTo x2"),
    y2: fin(y2, "curveTo y2"), x3: fin(x3, "curveTo x3"),
    y3: fin(y3, "curveTo y3")))

proc close*(p: var Path) =
  p.cmds.add(PathCmd(kind: pcClose))

proc addRect*(p: var Path, x, y, w, h: float64) =
  if w == 0.0 or h == 0.0:
    pdfFail("rectangle needs non-zero width and height")
  p.cmds.add(PathCmd(kind: pcRect, rx: fin(x, "rect x"),
    ry: fin(y, "rect y"), rw: fin(w, "rect w"), rh: fin(h, "rect h")))

proc pathOps*(p: Path): string =
  if p.cmds.len == 0:
    pdfFail("cannot paint an empty path")
  for c in p.cmds:
    case c.kind
    of pcMove: result.add(fmt"{c.x} {c.y} m ")
    of pcLine: result.add(fmt"{c.x} {c.y} l ")
    of pcCurve:
      result.add(fmt"{c.x1} {c.y1} {c.x2} {c.y2} {c.x3} {c.y3} c ")
    of pcRect: result.add(fmt"{c.rx} {c.ry} {c.rw} {c.rh} re ")
    of pcClose: result.add("h ")

proc paintOps*(p: Path, opts: FillOpts, strokeWidth = 1.0): string =
  ## `q <color> <path> <paint> Q` with balanced graphics state.
  ## Fill and/or stroke after W? No clipping here; see clipOps.
  var inner = p.pathOps()
  var paint = ""
  var prefix = ""
  if opts.hasFill:
    prefix.add(opts.fill.fillOp() & " ")
  if opts.hasStroke:
    let w = if opts.lineWidth > 0.0: opts.lineWidth
      elif strokeWidth > 0.0: strokeWidth
      else: 1.0
    if w != w or w == Inf or w == -Inf or w <= 0.0:
      pdfFail("line width must be positive")
    prefix.add(fmt"{w} w " & opts.stroke.strokeOp() & " ")
  if opts.hasFill and opts.hasStroke:
    paint = if opts.evenOdd: "B*" else: "B"
  elif opts.hasFill:
    paint = if opts.evenOdd: "f*" else: "f"
  else:
    paint = "S"
  "q " & prefix & inner & paint & " Q"

proc clipOps*(p: Path, evenOdd = false): string =
  "q " & p.pathOps() & (if evenOdd: "W* n Q" else: "W n Q")

const kappa = 0.5522847498

proc ellipsePath*(cx, cy, rx, ry: float64): Path =
  if rx <= 0.0 or ry <= 0.0 or rx != rx or ry != ry or
      cx != cx or cy != cy or rx == Inf or ry == Inf:
    pdfFail("ellipse needs finite positive radii")
  let kx = kappa * rx
  let ky = kappa * ry
  result.moveTo(cx + rx, cy)
  result.curveTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
  result.curveTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
  result.curveTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
  result.curveTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
  result.close()

proc lineOps*(x1, y1, x2, y2, width: float64, c: PdfColor): string =
  var p: Path
  p.moveTo(x1, y1)
  p.lineTo(x2, y2)
  p.paintOps(FillOpts(hasFill: false, hasStroke: true, stroke: c,
    lineWidth: width), width)

proc rectOps*(x, y, w, h: float64, opts: FillOpts): string =
  var p: Path
  p.addRect(x, y, w, h)
  p.paintOps(opts)

proc circleOps*(cx, cy, r: float64, opts: FillOpts): string =
  ellipsePath(cx, cy, r, r).paintOps(opts)

proc ellipseOps*(cx, cy, rx, ry: float64, opts: FillOpts): string =
  ellipsePath(cx, cy, rx, ry).paintOps(opts)
