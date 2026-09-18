import std/[tables, strutils, os, tempfiles, unittest]

import ../src/opendocs/docx
import ../src/opendocs/zip

const sampleDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="28"/></w:rPr><w:t>Title</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:i/><w:color w:val="FF0000"/></w:rPr><w:t>world</w:t></w:r><w:hyperlink r:id="rId5"><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>link</w:t></w:r></w:hyperlink></w:p>
<w:p><w:del><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins><w:r><w:t>here</w:t></w:r></w:ins></w:p>
<w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/><w:shd w:fill="DDDDDD"/></w:tcPr><w:p><w:r><w:t>wide</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800"/></w:sectPr>
</w:body></w:document>"""

proc packDoc(docXml: string, extra: seq[(string, string)] = @[]): seq[byte] =
  var w = newZipWriter()
  w.addFile("word/document.xml", docXml)
  for (name, body) in extra:
    w.addFile(name, body)
  w.toBytes()

suite "docx document.xml reader":
  test "paragraphs, runs, styles, numbering, hyperlink":
    let doc = readDocxBytes(packDoc(sampleDoc))
    check doc.blocks.len == 4
    let h = doc.blocks[0].paragraph
    check h.styleId == "Heading1"
    check h.align == "center"
    check h.runs.len == 1
    check h.runs[0].text == "Title"
    check h.runs[0].bold
    check h.runs[0].sizeHalfPts == 28
    let p = doc.blocks[1].paragraph
    check p.numId == 3
    check p.numIlvl == 0
    check p.runs.len == 3
    check p.runs[0].text == "Hello "
    check p.runs[1].text == "world"
    check p.runs[1].italic
    check p.runs[1].color == "FF0000"
    check p.runs[2].text == "link"
    check p.runs[2].underline
    check p.runs[2].hyperlinkRid == "rId5"

  test "tracked changes: wrappers kept, accept-view text":
    let doc = readDocxBytes(packDoc(sampleDoc))
    let kids = doc.blocks[2].paragraph.kids
    check kids.len == 2
    check kids[0].kind == pkDel
    check kids[0].rev.runs[0].delText == "gone"
    check kids[1].kind == pkIns
    check kids[1].rev.runs[0].text == "here"
    check flatText(doc).contains("\nhere\n")

  test "tables with spans and merges":
    let doc = readDocxBytes(packDoc(sampleDoc))
    let t = doc.blocks[3].table
    check t.rows.len == 2
    check t.rows[0].cells[0].gridSpan == 2
    check t.rows[0].cells[0].shading == "DDDDDD"
    check t.rows[1].cells[0].vMerge == "restart"
    check t.rows[1].cells[1].vMerge == "continue"

  test "section properties":
    let doc = readDocxBytes(packDoc(sampleDoc))
    check getPageSettings(doc).pgW == 11906
    check getPageSettings(doc).pgH == 16838
    check getPageSettings(doc).marginLeft == 1800

  test "flatText":
    let doc = readDocxBytes(packDoc(sampleDoc))
    check flatText(doc) == "Title\nHello worldlink\nhere\nwide\nA\nB"

const revDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p w:rsidR="00A1"><w:pPr w:rsidP="00B2"><w:ins w:id="20" w:author="Ann" w:date="2024-01-02"/><w:pPrChange w:id="22" w:author="Ann"><w:pPr><w:jc w:val="center"/></w:pPr></w:pPrChange></w:pPr><w:r w:rsidR="00C3"><w:rPr><w:del w:id="25" w:author="Bob"/><w:rPrChange w:id="26"><w:rPr><w:b/></w:rPr></w:rPrChange></w:rPr><w:t>a</w:t></w:r><w:ins w:id="10" w:author="Ann"><w:r><w:t>new</w:t></w:r><w:del w:id="11"><w:r><w:t>mid</w:t></w:r></w:del><w:moveFrom w:id="12"><w:r><w:t>ghost</w:t></w:r></w:moveFrom></w:ins><w:del w:id="13" w:author="Bob"><w:r><w:delText>old</w:delText></w:r><w:r><w:delInstrText>PAGE</w:delInstrText></w:r></w:del><w:moveFromRangeStart w:id="50" w:name="mv"/><w:moveToRangeEnd w:id="51" w:name="mv"/><w:customXmlDelRangeStart w:id="52" w:name="item" w:uri="urn:x" w:element="e"/></w:p>
<w:ins w:id="40" w:author="Ann"><w:p><w:r><w:t>in</w:t></w:r></w:p></w:ins>
<w:del w:id="41" w:author="Bob"><w:p><w:r><w:t>out</w:t></w:r></w:p></w:del>
<w:tbl><w:tblPr><w:tblPrChange w:id="37"><w:tblPr><w:tblStyle w:val="X"/></w:tblPr></w:tblPrChange></w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:tblGridChange w:id="38"><w:tblGrid><w:gridCol w:w="3000"/></w:tblGrid></w:tblGridChange></w:tblGrid><w:tr><w:trPr><w:ins w:id="34"/><w:trPrChange w:id="36"><w:trPr/></w:trPrChange></w:trPr><w:tc><w:tcPr><w:cellIns w:id="30" w:author="Ann"/><w:cellMerge w:id="32"/><w:tcPrChange w:id="33"><w:tcPr/></w:tcPrChange></w:tcPr><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:sectPr/></w:body></w:document>"""

suite "docx tracked changes reader":
  test "wrappers, ghost skip, ins>del splice":
    let doc = readDocxBytes(packDoc(revDoc))
    let kids = doc.blocks[0].paragraph.kids
    check kids.len == 3
    check kids[0].kind == pkRun
    check kids[0].run.text == "a"
    check kids[0].run.rsidR == "00C3"
    check kids[0].run.hasRDel
    check kids[0].run.rDel == RevisionMeta(id: "25", author: "Bob")
    check kids[0].run.hasRPrChange
    check kids[1].kind == pkIns
    check kids[1].rev.meta == RevisionMeta(id: "10", author: "Ann")
    check kids[1].rev.runs.len == 2 # ghost moveFrom skipped, del spliced
    check kids[1].rev.runs[0].text == "new"
    check kids[1].rev.runs[1].text == "mid"
    check kids[2].kind == pkDel
    check kids[2].rev.runs[0].delText == "old"
    check kids[2].rev.runs[1].delInstr
    check kids[2].rev.runs[1].instr.kind == fikPage

  test "paragraph marks, rsids, ranges":
    let doc = readDocxBytes(packDoc(revDoc))
    let p = doc.blocks[0].paragraph
    check p.rsidR == "00A1"
    check p.rsidP == "00B2"
    check p.hasPPrIns and p.pPrIns.author == "Ann"
    check p.hasPPrChange
    check p.pPrChange.ppr[].align == "center"
    check p.rangeMarkers.len == 3
    check p.rangeMarkers[0].kind == rmkMoveFromStart
    check p.rangeMarkers[0].tag == "w:moveFromRangeStart"
    check p.rangeMarkers[1].kind == rmkMoveToEnd
    check p.rangeMarkers[2].kind == rmkCustomXml
    check p.rangeMarkers[2].uri == "urn:x"
    check p.rangeMarkers[2].element == "e"
    check flatText(doc).contains("anewmid") # ins kept, del dropped
    check not flatText(doc).contains("old")

  test "body-level wrappers and table marks":
    let doc = readDocxBytes(packDoc(revDoc))
    check doc.blocks[1].kind == bkIns
    check doc.blocks[1].rev.meta.id == "40"
    check doc.blocks[2].kind == bkDel
    check flatText(doc).contains("in")
    check not flatText(doc).contains("out")
    let t = doc.blocks[3].table
    check t.hasTblPrChange and t.tblPrChange.meta.id == "37"
    check t.hasTblGridChange
    check t.rows[0].hasTrIns and t.rows[0].trIns.id == "34"
    check t.rows[0].hasTrPrChange
    let c = t.rows[0].cells[0]
    check c.hasTcIns and c.tcIns.author == "Ann"
    check c.hasTcMerge and c.tcMerge.id == "32"
    check c.hasTcPrChange

  test "unknown parts preserved":
    let doc = readDocxBytes(packDoc(sampleDoc,
      @[("word/settings.xml", "<w:settings/>"),
        ("word/media/image1.png", "\x89PNG")]))
    check doc.rawParts.hasKey("word/settings.xml")
    check doc.rawParts["word/media/image1.png"].len == 4

  test "missing document.xml is DocxError":
    var w = newZipWriter()
    w.addFile("word/styles.xml", "<w:styles/>")
    expect DocxError:
      discard readDocxBytes(w.toBytes())

  test "corrupt XML is DocxError":
    expect DocxError:
      discard readDocxBytes(packDoc("<w:document><w:body><w:p>"))

  test "mismatched tags are DocxError (strict)":
    expect DocxError:
      discard readDocxBytes(packDoc(
        """<w:document><w:body><w:p><w:r></w:p></w:r></w:body></w:document>"""))

  test "non-zip input is DocxError":
    var raw = newSeq[byte](4)
    raw[0] = 1; raw[1] = 2; raw[2] = 3; raw[3] = 4
    expect DocxError:
      discard readDocxBytes(raw)

const fullPkgDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Doc</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:numId w:val="7"/></w:numPr></w:pPr><w:r><w:t>item</w:t></w:r></w:p>
<w:p><w:r><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p><w:hyperlink r:id="rId10"><w:r><w:t>site</w:t></w:r></w:hyperlink></w:p>
</w:body></w:document>"""

const fullPkgStyles = """<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style><w:style w:type="character" w:styleId="Emph"><w:name w:val="Emphasis"/></w:style></w:styles>"""

const fullPkgNumbering = """<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="&#9679;"/></w:lvl></w:abstractNum><w:num w:numId="7"><w:abstractNumId w:val="2"/></w:num></w:numbering>"""

const fullPkgRels = """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/pic.png"/><Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/" TargetMode="External"/></Relationships>"""

const fullPkgTypes = """<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/><Override PartName="/word/media/pic.png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"""

proc packFull(): seq[byte] =
  var w = newZipWriter()
  w.addFile("word/document.xml", fullPkgDoc)
  w.addFile("word/styles.xml", fullPkgStyles)
  w.addFile("word/numbering.xml", fullPkgNumbering)
  w.addFile("word/_rels/document.xml.rels", fullPkgRels)
  w.addFile("[Content_Types].xml", fullPkgTypes)
  w.addFile("word/media/pic.png", @[137'u8, 80, 78, 71, 13])
  w.addFile("word/settings.xml", "<w:settings/>")
  w.toBytes()

suite "docx styles, numbering, rels, images":
  test "styles parsed":
    let doc = readDocxBytes(packFull())
    check doc.styles["Title"].name == "Title"
    check doc.styles["Title"].kind == "paragraph"
    check doc.styles["Emph"].kind == "character"
    check not doc.rawParts.hasKey("word/styles.xml")

  test "numbering resolved numId to levels":
    let doc = readDocxBytes(packFull())
    check doc.numbering[7].len == 1
    check doc.numbering[7][0].format == "bullet"
    check doc.blocks[1].paragraph.numId == 7

  test "hyperlink targets resolved":
    let doc = readDocxBytes(packFull())
    check doc.hyperlinks["rId10"] == "https://example.com/"
    check not doc.rawParts.hasKey("word/_rels/document.xml.rels")

  test "images extracted with content type, out of rawParts":
    let doc = readDocxBytes(packFull())
    check doc.images.len == 1
    check doc.images[0].relId == "rId9"
    check doc.images[0].contentType == "image/png"
    check doc.images[0].data == @[137'u8, 80, 78, 71, 13]
    check not doc.rawParts.hasKey("word/media/pic.png")
    check doc.rawParts.hasKey("word/settings.xml")

  test "drawing rid lands on run":
    let doc = readDocxBytes(packFull())
    check doc.blocks[2].paragraph.runs[0].drawingRid == "rId9"

  test "missing image target is DocxError":
    var w = newZipWriter()
    w.addFile("word/document.xml", fullPkgDoc)
    w.addFile("word/_rels/document.xml.rels", fullPkgRels)
    expect DocxError:
      discard readDocxBytes(w.toBytes())

const secDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:r><w:t>Body</w:t></w:r><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="1"/></w:r></w:p>
<w:sectPr><w:headerReference w:type="default" r:id="rId2"/><w:footerReference w:type="first" r:id="rId3"/><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
</w:body></w:document>"""

const secRels = """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>"""

proc packSecondary(): seq[byte] =
  var w = newZipWriter()
  w.addFile("word/document.xml", secDoc)
  w.addFile("word/_rels/document.xml.rels", secRels)
  w.addFile("word/header1.xml",
    """<w:hdr><w:p><w:r><w:t>Head</w:t></w:r></w:p></w:hdr>""")
  w.addFile("word/footer1.xml",
    """<w:ftr><w:p><w:r><w:t>Foot</w:t></w:r></w:p></w:ftr>""")
  w.addFile("word/footnotes.xml",
    """<w:footnotes><w:footnote w:id="1"><w:p><w:r><w:t>Note text</w:t></w:r></w:p></w:footnote></w:footnotes>""")
  w.addFile("word/endnotes.xml",
    """<w:endnotes><w:endnote w:id="5"><w:p><w:r><w:t>End text</w:t></w:r></w:p></w:endnote></w:endnotes>""")
  w.addFile("word/comments.xml",
    """<w:comments><w:comment w:id="0" w:author="Ann" w:date="2024-01-02" w:initials="A"><w:p><w:r><w:t>Fix this</w:t></w:r></w:p></w:comment></w:comments>""")
  w.addFile("docProps/core.xml",
    """<cp:coreProperties><dc:title>My Title</dc:title><dc:creator>Bob</dc:creator><dcterms:created>2024-05-01</dcterms:created><dcterms:modified>2024-05-02</dcterms:modified></cp:coreProperties>""")
  w.toBytes()

func blockText(b: Block): string =
  case b.kind
  of bkParagraph:
    for r in b.paragraph.runs: result.add r.text
  of bkTable: discard
  of bkTextbox:
    for tb in b.textbox.blocks: result.add blockText(tb)
  of bkSdt:
    for sb in b.sdt.blocks: result.add blockText(sb)
  of bkIns:
    for ib in b.rev.blocks: result.add blockText(ib)
  of bkDel: discard

suite "docx secondary parts":
  test "headers and footers via sectPr refs":
    let doc = readDocxBytes(packSecondary())
    check doc.sections[0].headerRefs == @[SectionRef(refKind: "default", relId: "rId2")]
    check doc.sections[0].footerRefs == @[SectionRef(refKind: "first", relId: "rId3")]
    check doc.sections[0].headers.len == 1
    check doc.sections[0].headers[0].refKind == "default"
    check blockText(doc.sections[0].headers[0].blocks[0]) == "Head"
    check doc.sections[0].footers.len == 1
    check doc.sections[0].footers[0].refKind == "first"
    check blockText(doc.sections[0].footers[0].blocks[0]) == "Foot"
    check not doc.rawParts.hasKey("word/header1.xml")
    check not doc.rawParts.hasKey("word/footer1.xml")

  test "footnotes, endnotes and run refs":
    let doc = readDocxBytes(packSecondary())
    check doc.footnotes.len == 1
    check doc.footnotes[0].id == 1
    check blockText(doc.footnotes[0].blocks[0]) == "Note text"
    check doc.blocks[0].paragraph.runs[1].footnoteRef == 1
    check doc.endnotes.len == 1
    check doc.endnotes[0].id == 5
    check blockText(doc.endnotes[0].blocks[0]) == "End text"

  test "comments with metadata":
    let doc = readDocxBytes(packSecondary())
    check doc.comments.len == 1
    check doc.comments[0].id == 0
    check doc.comments[0].author == "Ann"
    check doc.comments[0].date == "2024-01-02"
    check doc.comments[0].initials == "A"
    check blockText(doc.comments[0].blocks[0]) == "Fix this"

  test "core properties":
    let doc = readDocxBytes(packSecondary())
    check doc.coreProps.title == "My Title"
    check doc.coreProps.author == "Bob"
    check doc.coreProps.created == "2024-05-01"
    check doc.coreProps.modified == "2024-05-02"
    check not doc.rawParts.hasKey("docProps/core.xml")

  test "dangling header ref is DocxError":
    var w = newZipWriter()
    w.addFile("word/document.xml", secDoc)
    w.addFile("word/_rels/document.xml.rels",
      """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="nope.xml"/></Relationships>""")
    expect DocxError:
      discard readDocxBytes(w.toBytes())

  test "wrong header root is DocxError":
    var w = newZipWriter()
    w.addFile("word/document.xml", secDoc)
    w.addFile("word/_rels/document.xml.rels", secRels)
    w.addFile("word/header1.xml", "<w:ftr><w:p/></w:ftr>")
    w.addFile("word/footer1.xml",
      "<w:ftr><w:p><w:r><w:t>F</w:t></w:r></w:p></w:ftr>")
    expect DocxError:
      discard readDocxBytes(w.toBytes())

const richRunDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:pPr><w:outlineLvl w:val="1"/><w:keepNext/><w:tabs><w:tab w:val="right" w:pos="9000"/><w:tab w:val="decimal" w:pos="4500"/></w:tabs><w:pBdr><w:top w:val="single" w:sz="8" w:space="4" w:color="FF0000"/></w:pBdr></w:pPr><w:bookmarkStart w:id="3" w:name="ch1"/><w:r><w:rPr><w:rStyle w:val="Emph"/><w:caps/><w:b w:val="false"/><w:vertAlign w:val="superscript"/><w:spacing w:val="20"/><w:position w:val="4"/><w:kern w:val="24"/><w:shd w:fill="FFFF00"/><w:lang w:val="en-US"/><w:rFonts w:ascii="Arial" w:eastAsia="MS Gothic" w:hAnsi="Arial"/><w:color w:themeColor="accent1" w:themeShade="BF"/><w:szCs w:val="22"/><w:bCs/><w:noProof/></w:rPr><w:t>up</w:t></w:r><w:bookmarkEnd w:id="3"/><w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden</w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve">TOC \o "1-3"</w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>cached entry</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:br w:type="page"/></w:r><w:r><w:sym w:font="Symbol" w:char="F0FC"/></w:r><w:r><w:commentReference w:id="2"/></w:r></w:p>
</w:body></w:document>"""

suite "docx full reader: runs and paragraphs":
  test "extended run properties":
    let doc = readDocxBytes(packDoc(richRunDoc))
    let r = doc.blocks[0].paragraph.runs[0]
    check r.text == "up"
    check r.styleId == "Emph"
    check r.caps
    check not r.bold # w:val=false clears
    check r.vertAlign == "superscript"
    check r.spacingTwips == 20
    check r.positionPts == 4
    check r.kernHalfPts == 24
    check r.shading == "FFFF00"
    check r.lang == "en-US"
    check r.fonts == "Arial"
    check r.fontsEastAsia == "MS Gothic"
    check r.fontsHAnsi == "Arial"
    check r.colorTheme == "accent1"
    check r.colorShade == "BF"
    check r.sizeCsHalfPts == 22
    check r.boldCs
    check r.noProof
    check doc.blocks[0].paragraph.runs[1].vanish

  test "field markers typed, instructions kept off text":
    let doc = readDocxBytes(packDoc(richRunDoc))
    let txt = flatText(doc)
    check "TOC \\o" notin txt
    check "cached entry" in txt
    let runs = doc.blocks[0].paragraph.runs
    check runs[2].fldChar == fckBegin
    check runs[3].instrRaw == "TOC \\o \"1-3\""
    check runs[3].instr.kind == fikToc
    check runs[3].instr.toc.switches ==
      @[InstrSwitch(flag: "o", arg: "1-3", hasArg: true)]
    check runs[4].fldChar == fckSeparate
    check runs[5].text == "cached entry"
    check runs[6].fldChar == fckEnd

  test "page break and symbol":
    let doc = readDocxBytes(packDoc(richRunDoc))
    let runs = doc.blocks[0].paragraph.runs
    check runs[^3].text == "\f"
    check runs[^2].text == ""
    check runs[^2].symFont == "Symbol"
    check runs[^2].symChar == "F0FC"
    check runs[^1].commentRef == 2

  test "paragraph outline, keep, tabs, borders, bookmarks":
    let doc = readDocxBytes(packDoc(richRunDoc))
    let p = doc.blocks[0].paragraph
    check p.outlineLvl == 1
    check p.keepNext
    check p.tabs == @[TabStop(kind: "right", pos: 9000),
      TabStop(kind: "decimal", pos: 4500)]
    check p.borders.top.style == "single"
    check p.borders.top.sizeEighths == 8
    check p.borders.top.space == 4
    check p.borders.top.color == "FF0000"
    check p.bookmarks == @[Bookmark(id: 3, name: "ch1")]
    check doc.bookmarks == @[Bookmark(id: 3, name: "ch1")]

const nestedDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:tbl><w:tblPr><w:tblStyle w:val="Grid"/><w:tblW w:w="9000" w:type="dxa"/><w:jc w:val="center"/><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/></w:tblBorders><w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>
<w:tr><w:trPr><w:trHeight w:val="500" w:hRule="atLeast"/><w:tblHeader/></w:trPr><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:vAlign w:val="center"/></w:tcPr><w:p><w:r><w:t>outer</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>inner</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:tc><w:tc><w:p><w:r><w:t>side</w:t></w:r></w:p></w:tc></w:tr>
</w:tbl>
</w:body></w:document>"""

suite "docx full reader: true nested tables":
  test "nested table is a block in the cell":
    let doc = readDocxBytes(packDoc(nestedDoc))
    let t = doc.blocks[0].table
    check t.styleId == "Grid"
    check t.width == 9000
    check t.widthType == "dxa"
    check t.align == "center"
    check t.layout == "fixed"
    check t.grid == @[4500, 4500]
    check t.borders.top.style == "single"
    check t.rows.len == 1
    check t.rows[0].height == 500
    check t.rows[0].heightRule == "atLeast"
    check t.rows[0].isHeader
    let cell = t.rows[0].cells[0]
    check cell.width == 4500
    check cell.vAlign == "center"
    check cell.blocks.len == 2
    check cell.blocks[0].kind == bkParagraph
    check cell.blocks[1].kind == bkTable
    check cell.blocks[1].table.rows[0].cells[0].blocks[0].kind == bkParagraph
    check flatText(doc) == "outer\ninner\nside"

const drawDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
<w:body>
<w:p><w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="457200"/><wp:docPr id="1" name="pic1" descr="a pic"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId6"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p><w:r><w:drawing><wp:anchor behindDoc="1"><wp:positionH relativeFrom="page"/><wp:positionV relativeFrom="paragraph"/><wp:extent cx="100" cy="200"/><wp:docPr id="2" name="float" descr=""/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId7"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>
<w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:inline><wp:extent cx="10" cy="20"/><wp:docPr id="3" name="boxpic" descr=""/><a:graphic><a:graphicData><wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>boxed</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice><mc:Fallback><w:pict><w:t>fallback</w:t></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>
</w:body></w:document>"""

const drawRels = """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/a.png"/><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/b.png"/></Relationships>"""

proc packDraw(): seq[byte] =
  var w = newZipWriter()
  w.addFile("word/document.xml", drawDoc)
  w.addFile("word/_rels/document.xml.rels", drawRels)
  w.addFile("word/media/a.png", @[1'u8])
  w.addFile("word/media/b.png", @[2'u8])
  w.toBytes()

suite "docx full reader: drawings and textboxes":
  test "inline geometry in drawings table":
    let doc = readDocxBytes(packDraw())
    check doc.blocks[0].paragraph.runs[0].drawingRid == "rId6"
    check doc.drawings["rId6"].placement == dpInline
    check doc.drawings["rId6"].cxEmu == 914400
    check doc.drawings["rId6"].cyEmu == 457200
    check doc.drawings["rId6"].name == "pic1"
    check doc.drawings["rId6"].descr == "a pic"

  test "floating anchor geometry":
    let doc = readDocxBytes(packDraw())
    let d = doc.drawings["rId7"]
    check d.placement == dpAnchor
    check d.behindDoc
    check d.posHFrom == "page"
    check d.posVFrom == "paragraph"

  test "AlternateContent choice used, fallback skipped, textbox block":
    let doc = readDocxBytes(packDraw())
    check "fallback" notin flatText(doc)
    check doc.blocks[2].kind == bkParagraph
    check doc.blocks[3].kind == bkTextbox
    var t = ""
    for b in doc.blocks[3].textbox.blocks:
      if b.kind == bkParagraph:
        for r in b.paragraph.runs: t.add r.text
    check t == "boxed"

const numDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>x</w:t></w:r></w:p></w:body></w:document>"""

const numXml = """<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:suff w:val="tab"/><w:lvlJc w:val="left"/></w:lvl></w:abstractNum><w:num w:numId="9"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num><w:num w:numId="10"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1)"/></w:lvl></w:lvlOverride></w:num></w:numbering>"""

suite "docx full reader: numbering completion":
  test "start/suff/justification and overrides":
    var w = newZipWriter()
    w.addFile("word/document.xml", numDoc)
    w.addFile("word/numbering.xml", numXml)
    let doc = readDocxBytes(w.toBytes())
    check doc.numbering[9][0].start == 5
    check doc.numbering[9][0].format == "decimal"
    check doc.numbering[9][0].suffix == "tab"
    check doc.numbering[9][0].justification == "left"
    check doc.numbering[10][0].start == 3
    check doc.numbering[10][0].format == "upperRoman"
    check doc.numbering[10][0].text == "%1)"

const styleXml2 = """<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:styleId="H1" w:default="0"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Normal" w:default="1"><w:name w:val="Normal"/></w:style></w:styles>"""

const themeXml = """<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1></a:clrScheme></a:themeElements></a:theme>"""

suite "docx full reader: styles and theme":
  test "style relations and defaults":
    var w = newZipWriter()
    w.addFile("word/document.xml", numDoc)
    w.addFile("word/styles.xml", styleXml2)
    let doc = readDocxBytes(w.toBytes())
    check doc.styles["H1"].basedOn == "Normal"
    check doc.styles["H1"].next == "Normal"
    check doc.styles["H1"].qFormat
    check not doc.styles["H1"].isDefault
    check doc.styles["Normal"].isDefault

  test "theme colors and effectiveColor":
    var w = newZipWriter()
    w.addFile("word/document.xml", numDoc)
    w.addFile("word/theme/theme1.xml", themeXml)
    let doc = readDocxBytes(w.toBytes())
    check doc.themeColors["accent1"] == "4472C4"
    check doc.themeColors["dk1"] == "000000"
    check not doc.rawParts.hasKey("word/theme/theme1.xml")
    let explicit = Run(text: "x", color: "FF0000")
    check effectiveColor(explicit, doc.themeColors) == "FF0000"
    let themed = Run(text: "x", colorTheme: "accent1")
    check effectiveColor(themed, doc.themeColors) == "4472C4"
    let shaded = Run(text: "x", colorTheme: "accent1", colorShade: "80")
    check effectiveColor(shaded, doc.themeColors) == "223962"
    let tinted = Run(text: "x", colorTheme: "accent1", colorTint: "80")
    check effectiveColor(tinted, doc.themeColors) == "A1B8E1"
    let unknown = Run(text: "x", colorTheme: "nope")
    check effectiveColor(unknown, doc.themeColors) == ""

const secDoc2 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:r><w:t>one</w:t></w:r></w:p>
<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/><w:pgSz w:w="10000" w:h="10000" w:orient="landscape"/><w:pgMar w:top="100" w:right="100" w:bottom="100" w:left="100" w:header="50" w:footer="60" w:gutter="10"/><w:cols w:num="2" w:space="300"/><w:titlePg/><w:pgNumType w:fmt="upperRoman" w:start="3"/></w:sectPr></w:pPr><w:r><w:t>two</w:t></w:r></w:p>
<w:p><w:r><w:t>three</w:t></w:r></w:p>
<w:sectPr><w:headerReference w:type="even" r:id="rId2"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/><w:docGrid w:linePitch="360"/></w:sectPr>
</w:body></w:document>"""

const secRels2 = """<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/></Relationships>"""

suite "docx full reader: sections and getters":
  proc packSec(): seq[byte] =
    var w = newZipWriter()
    w.addFile("word/document.xml", secDoc2)
    w.addFile("word/_rels/document.xml.rels", secRels2)
    w.addFile("word/header1.xml",
      "<w:hdr><w:p><w:r><w:t>EH</w:t></w:r></w:p></w:hdr>")
    w.toBytes()

  test "pPr sectPr splits sections":
    let doc = readDocxBytes(packSec())
    check doc.sections.len == 2
    check flatText(doc) == "one\ntwo\nthree"
    check doc.blocks.len == 3 # flat flow preserved
    check doc.sections[0].props.sectType == "continuous"
    check doc.sections[0].props.orient == "landscape"
    check doc.sections[0].props.colsNum == 2
    check doc.sections[0].props.colsSpace == 300
    check doc.sections[0].props.titlePg
    check doc.sections[0].props.pgNumFmt == "upperRoman"
    check doc.sections[0].props.pgNumStart == 3
    check doc.sections[1].props.pgW == 11906
    check doc.sections[1].props.headerDist == 708
    check doc.sections[1].props.linePitch == 360

  test "getters":
    let doc = readDocxBytes(packSec())
    check getSections(doc).len == 2
    check getSection(doc, 0).props.orient == "landscape"
    check getPageSettings(doc).pgW == 11906
    check getPageSettings(doc, 0).pgW == 10000
    check getHeaders(doc).len == 1
    check getHeaders(doc, 1, "even").len == 1
    check getHeaders(doc, 1, "default").len == 0
    check getHeaders(doc, 0).len == 0
    check getFooters(doc).len == 0
    expect DocxError:
      discard getSection(doc, 5)
    expect DocxError:
      discard getPageSettings(doc, 5)

const miscDoc = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:bookmarkStart w:id="9" w:name="mark"/><w:r><w:t>t</w:t></w:r></w:p><w:sdt><w:sdtPr><w:alias w:val="box"/><w:tag w:val="t1"/></w:sdtPr><w:sdtContent><w:p><w:r><w:t>controlled</w:t></w:r></w:p></w:sdtContent></w:sdt><w:sectPr><w:pgSz w:w="1" w:h="1"/></w:sectPr></w:body></w:document>"""

suite "docx full reader: bookmarks, sdt, props":
  proc packMisc(): seq[byte] =
    var w = newZipWriter()
    w.addFile("word/document.xml", miscDoc)
    w.addFile("word/footnotes.xml",
      """<w:footnotes><w:footnote w:type="separator" w:id="0"><w:p><w:r><w:t>-</w:t></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:t>real</w:t></w:r></w:p></w:footnote></w:footnotes>""")
    w.addFile("docProps/app.xml",
      """<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Test</Application><Pages>2</Pages><Words>10</Words><Characters>50</Characters><Paragraphs>3</Paragraphs></Properties>""")
    w.addFile("docProps/custom.xml",
      """<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"><property pid="2" name="hello"><vt:lpwstr xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">world</vt:lpwstr></property><property pid="3" name="n"><vt:i4 xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">42</vt:i4></property></Properties>""")
    w.toBytes()

  test "bookmarks aggregated":
    let doc = readDocxBytes(packMisc())
    check doc.bookmarks == @[Bookmark(id: 9, name: "mark")]

  test "sdt transparent with record":
    let doc = readDocxBytes(packMisc())
    check doc.blocks[1].kind == bkSdt
    check doc.blocks[1].sdt.alias == "box"
    check doc.blocks[1].sdt.tag == "t1"
    check flatText(doc) == "t\ncontrolled"

  test "separator footnotes skipped":
    let doc = readDocxBytes(packMisc())
    check doc.footnotes.len == 1
    check doc.footnotes[0].id == 1

  test "app and custom properties":
    let doc = readDocxBytes(packMisc())
    check doc.appProps.application == "Test"
    check doc.appProps.pages == 2
    check doc.appProps.words == 10
    check doc.customProps == @[
      CustomProp(name: "hello", value: customStr("world")),
      CustomProp(name: "n", value: customInt(42))]
    check $doc.customProps[0].value == "world"
    check $doc.customProps[1].value == "42"

suite "docx acceptance: vendored fixtures":
  const fixDir = currentSourcePath().parentDir() / "fixtures" / "docx"

  test "no-crash sweep over all fixtures":
    var count = 0
    for f in walkFiles(fixDir / "*.docx"):
      let doc = readDocx(f)
      check doc.sections.len >= 1
      discard flatText(doc)
      inc count
    check count >= 15

  test "bookmark fixture names":
    let doc = readDocx(fixDir / "bookmark.docx")
    check doc.bookmarks.len == 1
    check doc.bookmarks[0].name == "ABCD-1234"
    check flatText(doc) == "Bookmarked"

  test "TOC fixture has entries, no instruction text":
    let doc = readDocx(fixDir / "toc0.docx")
    let txt = flatText(doc)
    check "TOC \\o" notin txt
    check txt.len > 0
    proc walk(bs: seq[Block], cb: proc(r: Run)) =
      for b in bs:
        case b.kind
        of bkParagraph:
          for r in b.paragraph.runs: cb(r)
        of bkTable:
          for row in b.table.rows:
            for cell in row.cells: walk(cell.blocks, cb)
        of bkTextbox: walk(b.textbox.blocks, cb)
        of bkSdt: walk(b.sdt.blocks, cb)
        of bkIns: walk(b.rev.blocks, cb)
        of bkDel: discard
    var tocKind, pageRefKind, beginCount, endCount = 0
    proc cb(r: Run) =
      case r.instr.kind
      of fikToc: inc tocKind
      of fikPageRef: inc pageRefKind
      else: discard
      case r.fldChar
      of fckBegin: inc beginCount
      of fckEnd: inc endCount
      else: discard
    for s in doc.sections: walk(s.blocks, cb)
    check tocKind >= 1
    check pageRefKind >= 1 # nested PAGEREF inside the TOC result
    check beginCount == endCount
    check beginCount > 0

  test "nested table fixture text":
    let doc = readDocx(fixDir / "nested_table.docx")
    check "Hello" in flatText(doc)

  test "tab and break fixture":
    let doc = readDocx(fixDir / "tab_and_break.docx")
    let txt = flatText(doc)
    check "Start" in txt
    check "\t" in txt
    check "\f" in txt

  test "floating image fixture drawings":
    let doc = readDocx(fixDir / "image_node_docx_floating.docx")
    check doc.drawings.len >= 1
    for _, d in doc.drawings:
      check d.placement == dpAnchor
      check d.cxEmu > 0

  test "textbox fixture content":
    let doc = readDocx(fixDir / "textbox.docx")
    var found = false
    proc scan(bs: seq[Block]) =
      for b in bs:
        case b.kind
        of bkTextbox: found = true
        of bkTable:
          for row in b.table.rows:
            for cell in row.cells: scan(cell.blocks)
        of bkSdt: scan(b.sdt.blocks)
        else: discard
    scan(doc.blocks)
    check found

suite "docx spillover to temp":
  const alwaysSpill = DocxReadOpts(spillThresholdBytes: 0)
  const fixDir = currentSourcePath().parentDir() / "fixtures" / "docx"

  test "spill path matches memory path":
    for name in ["hello.docx", "comment.docx", "nested_table.docx",
        "textbox.docx", "first_even_header.docx"]:
      let mem = readDocx(fixDir / name)
      let spl = readDocx(fixDir / name, alwaysSpill)
      check flatText(spl) == flatText(mem)
      check spl.blocks.len == mem.blocks.len
      check spl.sections.len == mem.sections.len
      check spl.rawParts.len == mem.rawParts.len
      check spl.images.len == mem.images.len
      check spl.bookmarks == mem.bookmarks

  test "no temp dirs left behind":
    let base = createTempDir("opendocs_", "_spillcheck")
    defer: removeDir(base)
    proc spillDirs(): int =
      for k in walkPattern(base / "opendocs_*_spill"):
        inc result
    check spillDirs() == 0
    discard readDocx(fixDir / "hello.docx",
      DocxReadOpts(spillThresholdBytes: 0, spillDir: base))
    check spillDirs() == 0
    # and none after a mid-parse failure either
    var w = newZipWriter()
    w.addFile("word/document.xml", "<w:document><w:body>")
    let bad = base / "bad.docx"
    w.writeZip(bad)
    expect DocxError:
      discard readDocx(bad,
        DocxReadOpts(spillThresholdBytes: 0, spillDir: base))
    check spillDirs() == 0

  test "unwritable spill dir is DocxError":
    let base = createTempDir("opendocs_", "_spillro")
    defer: removeDir(base)
    let notDir = base / "file"
    writeFile(notDir, "x")
    expect DocxError:
      discard readDocx(fixDir / "hello.docx",
        DocxReadOpts(spillThresholdBytes: 0, spillDir: notDir / "sub"))

  test "spill cap enforced":
    expect DocxError:
      discard readDocx(fixDir / "hello.docx",
        DocxReadOpts(spillThresholdBytes: 0, spillCapBytes: 10))

  test "big doc parses identically via spill":
    let dir = createTempDir("opendocs_", "_spillbig")
    defer: removeDir(dir)
    var body = ""
    for i in 1 .. 3000:
      body.add "<w:p><w:r><w:t>para " & $i & "</w:t></w:r></w:p>"
    var w = newZipWriter()
    w.addFile("word/document.xml",
      "<w:document><w:body>" & body &
      "<w:sectPr/></w:body></w:document>")
    let path = dir / "big.docx"
    w.writeZip(path)
    let mem = readDocx(path)
    let spl = readDocx(path, alwaysSpill)
    check spl.blocks.len == 3000
    check flatText(spl) == flatText(mem)
