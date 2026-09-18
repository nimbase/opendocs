## Full sheet extraction: document to pages of classified rows.
import std/os
import std/strutils
import ../src/opendocs/pdf

var d = openMappedDoc("tests" / "data" / "pdf" /
  "525J-001.pdf")
let sheet = d.extractSheet("1.4")
echo "sheet ", sheet.version, " pages: ", sheet.pageCount
for p in sheet.pages:
  echo "page ", p.index, " (", p.width, "x", p.height, ") rows: ",
    p.rows.len
  for r in p.rows:
    let preview = r.text.replace("\n", " / ")
    echo "  [", r.kind, "] ", r.size, "pt @(", r.x, ", ", r.y, ") ",
      preview[0 ..< min(64, preview.len)]
  for t in p.tables:
    echo "  table ", t.headers.len, " headers, ", t.rows.len,
      " rows @(", t.x, ", ", t.y, ")"
    if t.headers.len > 0:
      echo "    H: ", t.headers.join(" | ")
    for r in t.rows:
      echo "    R: ", r.join(" | ")
d.close()
