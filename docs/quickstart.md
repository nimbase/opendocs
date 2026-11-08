# Quickstart

## DOCX read

```nim
import opendocs/docx

let doc = readDocx("report.docx") # or readDocxBytes(bytes)
echo flatText(doc)

for b in doc.blocks:
  case b.kind
  of bkParagraph:
    for r in b.paragraph.runs:
      echo r.text, " bold=", r.bold
  of bkTable:
    echo "rows=", b.table.rows.len
  of bkTextbox: echo "textbox"
  of bkSdt: echo "sdt: ", b.sdt.alias
  of bkIns, bkDel: discard
```

## DOCX write

```nim
import opendocs/docx

var doc = newDocx(title = "Hello", author = "me")
doc.addParagraph("Hello world")
var t = newTable(2, 2)
t.cell(0, 0).blocks.add(Block(kind: bkParagraph, paragraph: newParagraph("a1")))
doc.addTable(t)
doc.writeDocx("out.docx")
```

## PDF read

```nim
import opendocs/pdf

let doc = openPdf("tests/data/pdf/m3b_text.pdf")
echo doc.version, " pages: ", doc.pageCount

var d = openDoc(readFile("tests/data/pdf/m3b_text.pdf"))
for run in d.extractText(0):
  echo "\"", run.text, "\" at (", run.x, ", ", run.y, ")"
```

## PDF write (high level)

```nim
import opendocs/pdf

var doc = newPdf()
doc.setTitle("Hello")
doc.heading("Hello writer")
doc.paragraph("Wrapped on shaped widths, auto page breaks.")
doc.save("hello.pdf")
doc.close()
```

## XLSX read

```nim
import opendocs/xlsx

let f = openXlsx("book.xlsx")
echo getSheetList(f)
for row in getRows(f, "Sheet1"):
  echo row.join("|")
closeXlsx(f)
```

## ZIP

```nim
import opendocs/zip

var w = newZipWriter()
w.addFile("hello.txt", "hi")
writeFile("a.zip", w.toBytes())

let a = openZip("a.zip")
echo filenames(a)
echo a.readEntry("hello.txt").len
```
