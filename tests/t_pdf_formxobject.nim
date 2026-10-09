## M7: Form XObject descent.
##
## A form is a content stream invoked by `Do`, carrying its own /Matrix,
## /BBox and /Resources. Its resources shadow the page's for the duration
## of the call, so the same name can denote a different font inside than
## out. Fixtures are the m7_* files from tests/gen_pdf_fixtures.nim.
##
## The tests that matter most here are the negative ones: a form whose
## resources shadow the page's, a BBox that clips, and the depth cap on a
## self-referential form. Those are the cases that fail silently.
import std/math
import std/os
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/images

const
  FormText = "tests/data/pdf/m7_form_text.pdf"
  FormImage = "tests/data/pdf/m7_form_image.pdf"
  FormNested = "tests/data/pdf/m7_form_nested.pdf"
  FormBBox = "tests/data/pdf/m7_form_bbox.pdf"
  FormShadow = "tests/data/pdf/m7_form_shadow.pdf"
  FormLoop = "tests/data/pdf/m7_form_loop.pdf"
  FormInline = "tests/data/pdf/m7_form_inline.pdf"
  FormNoRes = "tests/data/pdf/m7_form_nores.pdf"

proc runsText(path: string, page = 0): string =
  var d = openDoc(readFile(path))
  for r in d.extractText(page):
    result.add(r.text)

proc runs(path: string, page = 0): seq[(string, float64, float64)] =
  var d = openDoc(readFile(path))
  for r in d.extractText(page):
    result.add((r.text, r.x, r.y))

proc approx(a, b: float64, tol = 0.01): bool =
  abs(a - b) <= tol

proc baseFontOf(d: var PdfDoc, depth: int, name = "F1"): string =
  ## /BaseFont of `name` in the resource frame at `depth`, resolved
  ## through /Font. Empty when that frame does not define the font.
  for w in d.walkNested(0):
    if w.depth != depth:
      continue
    var fonts = w.resources.dictGet("Font")
    if fonts.kind == coRef:
      fonts = d.resolve(fonts)
    if fonts.kind != coDict:
      continue
    var f = fonts.dictGet(name)
    if f.kind == coRef:
      f = d.resolve(f)
    if f.kind == coDict or f.kind == coStream:
      return f.dictGet("BaseFont").name
  ""

test "form content is descended, not skipped":
  let t = runsText(FormText)
  check "Nested form text" in t
  check "Second form line" in t
  # The page's own text must still be there: descent adds, never replaces.
  check "Page level text" in t

test "form invocations stay visible as Do ahead of their expansion":
  # A form's own dictionary entries (notably /OC) scope everything the
  # invocation draws, so the Do must be emitted with the caller's frame
  # rather than swallowed by the descent.
  var d = openDoc(readFile(FormText))
  let ops = d.walkNested(0)
  var at = -1
  for i, w in ops:
    if w.op.name == "Do" and w.op.operands.len == 1 and
        w.op.operands[0].kind == coName and
        w.op.operands[0].name == "Fm1":
      at = i
  check at >= 0
  check ops[at].depth == 0
  # The page frame names the form, and the expansion follows: a q, the
  # form matrix cm, then depth-1 content.
  check ops[at].resources.dictGet("XObject").kind != coNull
  check ops[at + 1].op.name == "q"
  check ops[at + 2].op.name == "cm"
  check ops[at + 3].depth == 1

test "walkNested expands more ops than the flat page stream":
  var d = openDoc(readFile(FormText))
  let flat = d.walkPageOps(0).len
  let nested = d.walkNested(0).len
  check nested > flat

test "form matrix places nested text in device space":
  # The form translates by (100, 300) and draws at (10, 200) and
  # (10, 180), so the runs must land at (110, 500) and (110, 480).
  let r = runs(FormText)
  var found = false
  for (text, x, y) in r:
    if text == "Nested form text":
      check approx(x, 110.0)
      check approx(y, 500.0)
      found = true
  check found

test "walked op records depth and ctm":
  var d = openDoc(readFile(FormText))
  var sawForm = false
  for w in d.walkNested(0):
    if w.depth == 0:
      continue
    check w.depth == 1
    check approx(w.ctm[4], 100.0)
    check approx(w.ctm[5], 300.0)
    sawForm = true
  check sawForm

test "replaying the op list reproduces the walked ctm":
  # The synthesised q/cm/Q must be present in the output, otherwise a
  # consumer that folds operators linearly lands on a different CTM than
  # the one recorded on each op. This is the bug that made form text
  # vanish before the synthesised operators were emitted.
  var d = openDoc(readFile(FormText))
  let ops = d.walkNested(0)
  var gs = initGState()
  var mismatch = false
  for w in ops:
    if w.depth == 1 and w.op.name == "Td":
      if not (approx(gs.ctm[4], w.ctm[4]) and approx(gs.ctm[5], w.ctm[5])):
        mismatch = true
    gs.applyOp(w.op)
  check not mismatch

test "form resources shadow the page":
  # Page /F1 is Helvetica with plain WinAnsi; the form's /F1 is Courier
  # with /Differences [65 /alpha]. A cache keyed on the name alone would
  # hand back the page's decoder and mis-decode the form's text.
  var d = openDoc(readFile(FormShadow))
  var pageFontName = ""
  var formFontName = ""
  for w in d.walkNested(0):
    if w.op.name != "Tf" or w.op.operands.len < 1:
      continue
    if w.depth == 0: pageFontName = w.op.operands[0].name
    else: formFontName = w.op.operands[0].name
  check pageFontName == "F1"
  check formFontName == "F1"
  # Same resource name, different resolved fonts: this is what makes the
  # decoder cache key (depth, name) necessary rather than name alone.
  check baseFontOf(d, 0) == "Helvetica"
  check baseFontOf(d, 1) == "Courier"

test "bbox clips text outside the form":
  let t = runsText(FormBBox)
  check "Inside the box" in t
  check "Above the box" notin t

test "nested form composes both matrices":
  # Outer: scale 2, translate (10, 20). Inner: translate (5, 5).
  # Net offset is (2*5 + 10, 2*5 + 20) = (20, 30).
  let r = runs(FormNested)
  check r.len == 1
  check r[0][0] == "Deeply nested"
  check approx(r[0][1], 20.0)
  check approx(r[0][2], 30.0)

test "form without resources inherits the page frame":
  # Legal and common: a form may omit /Resources entirely.
  check "Inherited resources" in runsText(FormNoRes)

test "image inside a form is collected with its ctm":
  var d = openDoc(readFile(FormImage))
  let items = d.pageRawImages(0)
  check items.len == 1
  check items[0].raw.width == 2
  check items[0].raw.height == 1
  # The form scales by 2 and translates (50, 50).
  check approx(items[0].raw.ctm[0], 2.0)
  check approx(items[0].raw.ctm[4], 50.0)
  check approx(items[0].raw.ctm[5], 50.0)
  check items[0].raw.depth == 1

test "inline images are collected too":
  # One at page level, one inside the form.
  var d = openDoc(readFile(FormInline))
  let items = d.pageRawImages(0)
  check items.len == 2
  var depths: seq[int]
  for it in items:
    depths.add(it.raw.depth)
  check depths.contains(0)
  check depths.contains(1)
  for it in items:
    check it.raw.width == 2
    check it.raw.height == 1

test "self-referential form raises at the nesting cap":
  var d = openDoc(readFile(FormLoop))
  expect(PdfError):
    discard d.extractText(0)

test "nesting cap is configurable and honoured":
  var d = openDoc(readFile(FormNested), defaultPdfLimits())
  check d.extractText(0).len == 1
  var tight = openDoc(readFile(FormNested),
    PdfLimits(maxPages: 1000, maxScanBytes: 8192, maxObjects: 200000,
      maxWalkDepth: 32, maxContentOps: 100000, maxImagePixels: 100000000,
      maxNestedXObject: 0))
  # A document that uses a form is unreadable at a zero nesting cap.
  # Raising is deliberate: silently skipping the form would return no
  # text and look like a successful extraction of a blank page.
  expect(PdfError):
    discard tight.extractText(0)

test "flat page stream still excludes form content":
  # walkPageOps is documented as the non-expanding view; consumers that
  # interpret operators must use walkNested.
  var d = openDoc(readFile(FormText))
  var seenDo = false
  for op in d.walkPageOps(0):
    if op.name == "Do":
      seenDo = true
  check seenDo
  check d.walkPageOps(0).len < d.walkNested(0).len