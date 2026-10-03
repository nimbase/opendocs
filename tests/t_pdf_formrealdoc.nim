## Real-world regression checks for the Form XObject walk.
##
## Both checked-in real documents (a 458 kB technical paper and a 1.5 MB
## Japanese Intel/OpenMP manual) contain no /Subtype /Form XObject at
## all, verified by walking every live object including those inside
## object streams. Their extraction results are therefore unchanged by
## M7, which is exactly the property worth pinning: adding descent must
## not perturb documents that do not use forms.
##
## The forms themselves are covered by tests/t_pdf_formxobject.nim.
import std/os
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/images

const
  Big = "tests/data/pdf/file-example_PDF_500_kB.pdf"
  Cjk = "tests/data/pdf/525J-001.pdf"

proc walkCos(o: CosObj, f: proc(x: CosObj) {.closure.}) =
  case o.kind
  of coDict:
    for v in o.vals:
      walkCos(v, f)
    f(o)
  of coStream:
    for v in o.streamVals:
      walkCos(v, f)
    f(o)
  of coArray:
    for v in o.items:
      walkCos(v, f)
  else:
    discard

proc countSubtype(path: string, want: string): int =
  var d = openDoc(readFile(path))
  var hits = 0
  for num, entry in d.xref.entries:
    if not entry.live:
      continue
    var o: CosObj
    try:
      o = d.resolve(CosObj(kind: coRef, refNum: num, refGen: 0))
    except PdfError:
      continue
    walkCos(o, proc(x: CosObj) =
      let st = x.dictGet("Subtype")
      if st.kind == coName and st.name == want:
        inc hits)
  hits

proc allText(path: string): string =
  var d = openDoc(readFile(path))
  for p in 0 ..< d.pageCount():
    for r in d.extractText(p):
      result.add(r.text)

test "real-world documents contain no form xobjects":
  # Pins the premise the next two tests rely on. If a fixture is ever
  # replaced with one that does use forms, these two will fail loudly and
  # the form-specific assertions belong in t_pdf_formxobject.nim.
  check countSubtype(Big, "Form") == 0
  check countSubtype(Cjk, "Form") == 0

test "nested walk is a no-op on documents without forms":
  var d = openDoc(readFile(Big))
  for p in 0 ..< d.pageCount():
    check d.walkNested(p).len == d.walkPageOps(p).len

test "nested walk never exceeds the operator cap":
  # Descent adds operators, so a tight per-stream cap must still fire
  # rather than truncating silently.
  var tight = openDoc(readFile(Big),
    PdfLimits(maxPages: 1000, maxScanBytes: 8192, maxObjects: 200000,
      maxWalkDepth: 32, maxContentOps: 5, maxImagePixels: 100000000,
      maxNestedXObject: 12))
  var raised = false
  try:
    discard tight.extractText(0)
  except PdfError:
    raised = true
  check raised

test "large real-world document still extracts":
  let t = allText(Big)
  check t.len > 1000

test "cjk real-world document still extracts":
  let t = allText(Cjk)
  check t.len > 1000

test "image collection is unchanged on documents without forms":
  var d = openDoc(readFile(Big))
  var total = 0
  for p in 0 ..< d.pageCount():
    for it in d.pageRawImages(p):
      check it.raw.depth == 0
      inc total
  check total == countSubtype(Big, "Image")