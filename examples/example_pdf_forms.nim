## Form fields: list, inspect, fill, reset, and flatten.
##
## Builds a one-page form (text field, checkbox, dropdown) with a tiny
## inline assembler, then walks the whole fill/reset/flatten lifecycle.
import std/strutils
import ../src/opendocs/pdf
import ../src/opendocs/pdf/docmodel

proc assemble(objs: seq[string]): string =
  result = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int] = @[]
  for i, body in objs:
    offsets.add(result.len)
    result.add($(i + 1) & " 0 obj\n" & body & "\nendobj\n")
  let xrefPos = result.len
  result.add("xref\n0 " & $(objs.len + 1) & "\n")
  result.add("0000000000 65535 f \n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    result.add(s & " 00000 n \n")
  result.add("trailer\n<< /Size " & $(objs.len + 1) &
    " /Root 1 0 R >>\nstartxref\n" & $xrefPos & "\n%%EOF\n")

proc streamObj(dict, payload: string): string =
  "<< " & dict & " /Length " & $payload.len & " >>\nstream\n" &
    payload & "\nendstream"

proc formPdf(): string =
  let content = "BT /Helv 12 Tf 50 350 Td (Sign up) Tj ET"
  assemble(@[
    "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] " &
      "/Resources << /Font << /Helv 6 0 R >> >> " &
      "/Annots [5 0 R 7 0 R 8 0 R] /Contents 9 0 R >>",
    "<< /Fields [5 0 R 7 0 R 8 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 300 200 320] " &
      "/FT /Tx /T (Name) /TU (Your full name) /V (Ann) " &
      "/DA (/Helv 12 Tf 0 g) /MaxLen 20 /P 3 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 270 62 282] " &
      "/FT /Btn /T (Agree) /V /Off /AS /Off " &
      "/AP << /N << /Yes 10 0 R /Off 11 0 R >> >> /P 3 0 R >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 230 150 250] " &
      "/FT /Ch /Ff 131072 /T (City) /V (Oslo) " &
      "/Opt [(Oslo) (Bergen)] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>",
    streamObj("", content),
    "<< /Length 0 >>\nstream\n\nendstream",
    "<< /Length 0 >>\nstream\n\nendstream",
  ])

let base = formPdf()

# List every field with its label, kind, and current value.
var d = openDoc(base)
for f in formFields(d):
  echo f.name, " [", f.kind, "] label='", f.label,
    "' value='", f.value, "'"

# Inspect one field in depth.
let city = getField(d, "City")
echo "City options: ", city.options
echo "City font: ", city.fontName, " ", city.fontSize

# Fill each kind (each call returns new bytes; chain them).
let v1 = fillText(base, "Name", "Bob")
let v2 = setCheck(v1, "Agree", true)
let v3 = selectChoice(v2, "City", "Bergen")
var filled = openDoc(v3)
echo "filled Name=", getField(filled, "Name").value,
  " Agree=", isChecked(getField(filled, "Agree")),
  " City=", getField(filled, "City").value

# Reset one field to its default (empty here: no /DV was given).
let v4 = resetFields(v3, @["City"])
var reverted = openDoc(v4)
echo "reset City=", getField(reverted, "City").value

# Flatten: values bake into page content, widgets go away.
let flat = flattenFields(v3)
var f = openDoc(flat)
var texts: seq[string] = @[]
for r in f.extractText(0):
  texts.add(r.text)
echo "flattened text: ", texts.join(" | ")
echo "fields left: ", fieldNames(f).len

writeFile("form.pdf", v3)
writeFile("form-flat.pdf", flat)
echo "wrote form.pdf and form-flat.pdf"
