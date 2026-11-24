## Page organize + writer drafts (M16a–c): rotation, boxes, delete,
## append, outlines, page labels, link/text annotations.
##
## Rotation and boxes edit page dicts through PdfUpdate (one appended
## section per call; chain calls to change several pages). Delete filters
## a builder's page list; append transplants donor pages via merge.copyPage
## (encrypted donors fail loudly there). Append copies pages only: outlines,
## names and destinations are not rewired.
##
## Outlines, labels and annotations are builder drafts flushed by
## buildPdf: outline targets are builder page indexes, label starts are
## validated against the final page count, annotation rects normalize
## reversed corners (non-finite fails). Appearance streams are not
## generated (needs a renderer).

import ./lexer
import ./cos
import ./docmodel
import ./write
import ./merge
import ./types

const pageBoxes* = ["MediaBox", "CropBox", "TrimBox", "BleedBox", "ArtBox"]

proc pageObjectNums(d: var PdfDoc): seq[int] =
  for p in d.pageRefs():
    if p.pageRef.kind != coRef:
      pdfFail("page tree leaf is not an indirect reference")
    result.add(p.pageRef.refNum)

proc setPageRotation*(u: var PdfUpdate, page, degrees: int) =
  ## Set absolute /Rotate for one 0-based page. Normalizes to
  ## 0/90/180/270; anything else fails. 0 removes /Rotate (the default).
  if degrees mod 90 != 0:
    pdfFail("page rotation must be a multiple of 90, got " & $degrees)
  let norm = ((degrees mod 360) + 360) mod 360
  var d = openDoc(fromString(u.base), u.limits)
  let nums = d.pageObjectNums()
  if page < 0 or page >= nums.len:
    pdfFail("page index " & $page & " out of range (0.." &
      $(nums.len - 1) & ")")
  let pdict = d.resolve(CosObj(kind: coRef, refNum: nums[page], refGen: 0))
  if pdict.kind != coDict:
    pdfFail("page tree leaf is not a dictionary")
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  for i, k in pdict.keys:
    if k == "Rotate":
      continue
    keys.add(k)
    vals.add(pdict.vals[i])
  if norm != 0:
    keys.add("Rotate")
    vals.add(CosObj(kind: coInt, ival: norm))
  discard u.updateObject(nums[page],
    writeCos(CosObj(kind: coDict, keys: keys, vals: vals)))

proc setPageBox*(u: var PdfUpdate, page: int, box: string,
    rect: array[4, float64]) =
  ## Set a page box (/MediaBox, /CropBox, /TrimBox, /BleedBox, /ArtBox).
  ## Corners normalize (reversed fixed); zero-size or non-finite fails.
  var okBox = false
  for b in pageBoxes:
    if b == box:
      okBox = true
      break
  if not okBox:
    pdfFail("unknown page box " & box)
  for v in rect:
    if v != v or v == Inf or v == -Inf:
      pdfFail("page box has non-finite coordinate")
  let x1 = min(rect[0], rect[2])
  let y1 = min(rect[1], rect[3])
  let x2 = max(rect[0], rect[2])
  let y2 = max(rect[1], rect[3])
  if x2 <= x1 or y2 <= y1:
    pdfFail("page box has non-positive size")
  var d = openDoc(fromString(u.base), u.limits)
  let nums = d.pageObjectNums()
  if page < 0 or page >= nums.len:
    pdfFail("page index " & $page & " out of range (0.." &
      $(nums.len - 1) & ")")
  let pdict = d.resolve(CosObj(kind: coRef, refNum: nums[page], refGen: 0))
  if pdict.kind != coDict:
    pdfFail("page tree leaf is not a dictionary")
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  var replaced = false
  for i, k in pdict.keys:
    if k == box:
      keys.add(k)
      vals.add(CosObj(kind: coArray, items: @[
        CosObj(kind: coFloat, fval: x1),
        CosObj(kind: coFloat, fval: y1),
        CosObj(kind: coFloat, fval: x2),
        CosObj(kind: coFloat, fval: y2)]))
      replaced = true
    else:
      keys.add(k)
      vals.add(pdict.vals[i])
  if not replaced:
    keys.add(box)
    vals.add(CosObj(kind: coArray, items: @[
      CosObj(kind: coFloat, fval: x1),
      CosObj(kind: coFloat, fval: y1),
      CosObj(kind: coFloat, fval: x2),
      CosObj(kind: coFloat, fval: y2)]))
  discard u.updateObject(nums[page],
    writeCos(CosObj(kind: coDict, keys: keys, vals: vals)))

proc deletePages*(b: var PdfBuilder, keep: seq[int]) =
  ## Keep only `keep` (0-based builder page indexes, in the given order).
  ## Empty keep fails; out-of-range indexes fail.
  if keep.len == 0:
    pdfFail("deletePages needs at least one page index to keep")
  var kids: seq[int] = @[]
  for k in keep:
    if k < 0 or k >= b.kids.len:
      pdfFail("page index " & $k & " out of range (0.." &
        $(b.kids.len - 1) & ")")
    kids.add(b.kids[k])
  b.kids = kids

proc appendPages*(b: var PdfBuilder, src: string, pages: seq[int]) =
  ## Transplant `pages` (0-based donor indexes) into the builder.
  ## Encrypted donors fail loudly via copyPage.
  var donor = openDoc(fromString(src), defaultPdfLimits())
  for p in pages:
    discard b.copyPage(donor, p)

proc addOutline*(b: var PdfBuilder, title: string,
    targetPage: int, parent = -1): int =
  ## Draft one outline item pointing at builder page `targetPage`.
  ## `parent` is a draft index (-1 for top level). Returns the draft
  ## index for use as a later parent. Flushed by buildPdf with /Dest
  ## [page /Fit]; siblings chain via /Prev//Next, parents carry
  ## /First//Last//Count (always open).
  if targetPage < 0 or targetPage >= b.kids.len:
    pdfFail("outline target page " & $targetPage & " out of range")
  if parent < -1 or parent >= b.outlineDrafts.len:
    pdfFail("outline parent " & $parent & " out of range")
  result = b.outlineDrafts.len
  b.outlineDrafts.add((title, targetPage, parent))

proc setPageLabels*(b: var PdfBuilder,
    labels: seq[tuple[style, prefix: string, start, first: int]]) =
  ## Draft the document /PageLabels number tree. `start` is a 0-based
  ## page index, `style` one of "" (prefix-only) D R r A a, `first`
  ## >= 1. Validated and sorted by buildPdf; duplicates fail there.
  for l in labels:
    if l.style notin ["", "D", "R", "r", "A", "a"]:
      pdfFail("unknown page label style '" & l.style & "'")
    if l.first < 1:
      pdfFail("page label /St must be >= 1")
    if l.start < 0:
      pdfFail("page label start " & $l.start & " out of range")
  b.labelDrafts = @[]
  for l in labels:
    b.labelDrafts.add(l)

proc normRect(rect: array[4, float64], what: string): array[4, float64] =
  for v in rect:
    if v != v or v == Inf or v == -Inf:
      pdfFail(what & " has non-finite coordinate")
  [min(rect[0], rect[2]), min(rect[1], rect[3]),
    max(rect[0], rect[2]), max(rect[1], rect[3])]

proc pushAnnot(b: var PdfBuilder, page: int, d: CosObj) =
  if page < 0 or page >= b.kids.len:
    pdfFail("annotation page " & $page & " out of range")
  if d.kind != coDict:
    pdfFail("annotation is not a dictionary")
  b.annotDrafts.add((page, writeCos(d)))

proc addLink*(b: var PdfBuilder, page: int, rect: array[4, float64],
    uri: string) =
  ## Draft a /Link annotation with a /URI action. No appearance
  ## stream is generated.
  if uri.len == 0:
    pdfFail("link annotation needs a non-empty URI")
  let r = normRect(rect, "link annotation /Rect")
  let d = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Rect", "Border", "A"],
    vals: @[CosObj(kind: coName, name: "Annot"),
      CosObj(kind: coName, name: "Link"),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coFloat, fval: r[0]),
        CosObj(kind: coFloat, fval: r[1]),
        CosObj(kind: coFloat, fval: r[2]),
        CosObj(kind: coFloat, fval: r[3])]),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coInt, ival: 0), CosObj(kind: coInt, ival: 0),
        CosObj(kind: coInt, ival: 1)]),
      CosObj(kind: coDict, keys: @["S", "URI"],
        vals: @[CosObj(kind: coName, name: "URI"),
          CosObj(kind: coStr, sval: uri)])])
  b.pushAnnot(page, d)

proc addInternalLink*(b: var PdfBuilder, page: int,
    rect: array[4, float64], targetPage: int) =
  ## Draft a /Link annotation with an explicit /Dest to builder page
  ## `targetPage`. Fits the whole page (/Fit).
  if targetPage < 0 or targetPage >= b.kids.len:
    pdfFail("internal link target page " & $targetPage & " out of range")
  let r = normRect(rect, "link annotation /Rect")
  let d = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Rect", "Border", "Dest"],
    vals: @[CosObj(kind: coName, name: "Annot"),
      CosObj(kind: coName, name: "Link"),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coFloat, fval: r[0]),
        CosObj(kind: coFloat, fval: r[1]),
        CosObj(kind: coFloat, fval: r[2]),
        CosObj(kind: coFloat, fval: r[3])]),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coInt, ival: 0), CosObj(kind: coInt, ival: 0),
        CosObj(kind: coInt, ival: 1)]),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coRef, refNum: b.kids[targetPage], refGen: 0),
        CosObj(kind: coName, name: "Fit")])])
  b.pushAnnot(page, d)

proc addTextAnnot*(b: var PdfBuilder, page: int,
    rect: array[4, float64], contents: string) =
  ## Draft a /Text annotation. Empty contents fails.
  if contents.len == 0:
    pdfFail("text annotation needs non-empty /Contents")
  let r = normRect(rect, "text annotation /Rect")
  let d = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Rect", "Contents"],
    vals: @[CosObj(kind: coName, name: "Annot"),
      CosObj(kind: coName, name: "Text"),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coFloat, fval: r[0]),
        CosObj(kind: coFloat, fval: r[1]),
        CosObj(kind: coFloat, fval: r[2]),
        CosObj(kind: coFloat, fval: r[3])]),
      CosObj(kind: coStr, sval: contents)])
  b.pushAnnot(page, d)
