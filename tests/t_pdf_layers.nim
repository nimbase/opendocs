## P6 tests: optional content groups / layers.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const Layers = "tests/data/pdf/layers.pdf"
const LayersBaseOff = "tests/data/pdf/layers_baseoff.pdf"

test "layers report names and default state":
  var d = openDoc(readFile(Layers))
  let ls = d.docLayers()
  check ls.len == 4
  check ls[0].name == "Draft marks"
  check ls[0].on
  check ls[0].intent == ""
  check ls[1].name == "Review"
  check not ls[1].on
  check ls[1].intent == "View"
  check "Print" in ls[1].usage
  check ls[2].name == "Hidden"
  check ls[2].on
  check ls[2].intent == "View/Design"
  check ls[3].name == "Inline"
  check ls[3].objNum == -1
  check ls[3].on

test "base off with explicit on":
  var d = openDoc(readFile(LayersBaseOff))
  let ls = d.docLayers()
  check ls.len == 2
  check ls[0].name == "A"
  check ls[0].on
  check ls[1].name == "B"
  check not ls[1].on

test "ocg numbers listed":
  var d = openDoc(readFile(Layers))
  let ocgs = d.layerOCGs()
  check ocgs.len == 4
  check ocgs[0].name == "Draft marks"
  check ocgs[0].objNum == 5
  check ocgs[3].objNum == -1

test "no ocproperties reads empty":
  var d = openDoc(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  check d.docLayers().len == 0
  check d.layerOCGs().len == 0

test "malformed ocproperties fails loudly":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R /OCProperties 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    "<< /OCGs 5 0 R >>",
    "<< /Type /OCG /Name (A) >>"])
  var d = openDoc(data)
  expect PdfError:
    discard d.docLayers()

test "malformed ocg entry fails naming the group":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R /OCProperties 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    "<< /OCGs [5 0 R] /D << >> >>",
    "<< /Type /OCG /Name 42 >>"])
  var d = openDoc(data)
  var msg = ""
  try:
    discard d.docLayers()
  except PdfError as e:
    msg = e.msg
  check "optional content group 0" in msg
