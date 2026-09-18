## Document text plus exact search, with a caller-side fuzzy demo.
##
## Exact search is stdlib-only. The fuzzy part imports openparser,
## which resolves from the local clue checkout; opengraphics itself
## does not depend on it.
import std/os
import ../src/opendocs/pdf
import openparser/fuzzy

var d = openMappedDoc("tests" / "data" / "pdf" /
  "file-example_PDF_500_kB.pdf")
let doc = d.extractDocumentText("1.4")
echo "pages: ", doc.pageCount

for h in doc.searchText("Lorem"):
  echo "exact p", h.page, " line ", h.line, " col ", h.col, ": ",
    h.excerpt

var lines: seq[string] = @[]
for p in doc.pages:
  for b in p.blocks:
    lines.add(b.text)
for m in fuzzySearch("lorem", lines,
    FuzzyOptions(limit: 3, minScore: 1.0)):
  echo "fuzzy score ", m.score, ": ", m.text[0 ..< min(60, m.text.len)]
d.close()
