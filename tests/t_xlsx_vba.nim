## XLSX VBA integration: `xl/vbaProject.bin` through `opendocs/ole2`.
##
## The macro part rides along untouched in the package reader (see the
## pre-existing "macro-style package" test in `t_xlsx.nim`); these
## tests cover the read-only VBA surface (`hasVbaProject`,
## `getVbaProject`, `readVbaStream`, `getSheetCodeName`,
## `checkVbaConsistency`) plus the encrypted-vs-legacy OLE branch in
## `openXlsxBytes`. The real `vbaProject.bin` comes from the checked-in
## `tests/fixtures/ole/` copy of the excelize reference file.

import std/[unittest, os, strutils]
import opendocs/xlsx
import opendocs/zip
import ole_build

const
  NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  NsRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  NsPkg = "http://schemas.openxmlformats.org/package/2006/relationships"
  VbaBin = "tests/fixtures/ole/vbaProject.bin"

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

func strOf(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc macroPkg(vba: seq[byte]): seq[byte] =
  var w = newZipWriter()
  w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
    NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  w.addFile("xl/workbook.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="M" sheetId="1" r:id="rId1"/></sheets></workbook>""")
  w.addFile("xl/_rels/workbook.xml.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
    NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""")
  w.addFile("xl/worksheets/sheet1.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1"><v>9</v></c></row></sheetData></worksheet>""")
  w.addFile("xl/vbaProject.bin", vba)
  w.toBytes()

suite "xlsx vba integration":
  test "real macro part lists through getVbaProject":
    let f = openXlsxBytes(macroPkg(bytesOf(readFile(VbaBin))))
    defer: f.closeXlsx()
    check f.hasVbaProject()
    let vba = f.getVbaProject()
    check vba.present
    check vba.entries.len == 14
    var names: seq[string] = @[]
    for e in vba.entries: names.add e.name
    check "VBA/dir" in names
    check "VBA/Module1" in names
    check "PROJECT" in names
    check "PROJECTwm" in names
    check f.readVbaStream("VBA/dir").len == 883
    check strOf(f.readVbaStream("PROJECT")).startsWith(
      "ID=\"{393F1BD5-8571-43B5-BE00-73D2AA4AA62C}\"")
    check f.readVbaStream("project").len == 578 # case-insensitive

  test "absent part yields present=false and loud reads":
    var w = newZipWriter()
    w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
    w.addFile("xl/workbook.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="M" sheetId="1" r:id="rId1"/></sheets></workbook>""")
    w.addFile("xl/_rels/workbook.xml.rels",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""")
    w.addFile("xl/worksheets/sheet1.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData/></worksheet>""")
    let f = openXlsxBytes(w.toBytes())
    defer: f.closeXlsx()
    check not f.hasVbaProject()
    let vba = f.getVbaProject()
    check not vba.present
    check vba.entries.len == 0
    expect XlsxError:
      discard f.readVbaStream("VBA/dir")

  test "corrupt macro part fails loudly on access, not on open":
    let f = openXlsxBytes(macroPkg(
      @[0xD0'u8, 0xCF, 0x11, 0xE0, 0xAA, 0xBB, 0xCC]))
    defer: f.closeXlsx()
    check f.hasVbaProject() # part rides along untouched
    expect XlsxError:
      discard f.getVbaProject()
    expect XlsxError:
      discard f.readVbaStream("PROJECT")

  test "missing macro stream is distinguishable":
    let f = openXlsxBytes(macroPkg(bytesOf(readFile(VbaBin))))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.readVbaStream("VBA/nope")

  test "spilled packages expose vba streams too":
    let f = openXlsxBytes(macroPkg(bytesOf(readFile(VbaBin))),
      XlsxReadOpts(spillThresholdBytes: 0))
    defer: f.closeXlsx()
    check f.spillDir != ""
    check f.readVbaStream("VBA/dir").len == 883
    f.closeXlsx()

  test "sheet codeName reads, never joins":
    var w = newZipWriter()
    w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
    w.addFile("xl/workbook.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="M" sheetId="1" r:id="rId1"/><sheet name="N" sheetId="2" r:id="rId2"/></sheets></workbook>""")
    w.addFile("xl/_rels/workbook.xml.rels",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet2.xml"/></Relationships>""")
    w.addFile("xl/worksheets/sheet1.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetPr codeName="Sheet1"/><sheetData/></worksheet>""")
    w.addFile("xl/worksheets/sheet2.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData/></worksheet>""")
    let f = openXlsxBytes(w.toBytes())
    defer: f.closeXlsx()
    check f.getSheetCodeName("M") == "Sheet1"
    check f.getSheetCodeName("N") == ""

suite "vba extension consistency":
  test "strict workbooks with macro parts raise":
    let f = openXlsxBytes(macroPkg(bytesOf(readFile(VbaBin))))
    defer: f.closeXlsx()
    expect XlsxError:
      f.checkVbaConsistency(".xlsx")
    expect XlsxError:
      f.checkVbaConsistency("REPORT.XLTX")
    f.checkVbaConsistency(".xlsm") # macro ext: no-op
    f.checkVbaConsistency("xltm")
    f.checkVbaConsistency("xlam")
    f.checkVbaConsistency("") # unknown: no-op
    f.checkVbaConsistency("report.xlsm") # filename form works

  test "plain workbooks pass every extension":
    var w = newZipWriter()
    w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
    w.addFile("xl/workbook.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="M" sheetId="1" r:id="rId1"/></sheets></workbook>""")
    let f = openXlsxBytes(w.toBytes())
    defer: f.closeXlsx()
    f.checkVbaConsistency(".xlsx") # no part: fine
    f.checkVbaConsistency(".xlsm") # macro ext without part: legal

suite "ole open branch":
  test "truncated magic is legacy, encrypted package is distinct":
    var legacy = @[0xD0'u8, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    try:
      discard openXlsxBytes(legacy)
      fail()
    except XlsxError as e:
      check "legacy" in e.msg
    # Minimal CFB carrying EncryptedPackage reads as passworded.
    var probe = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("EncryptedPackage", 2, -1, 3, -1, 2, 100),
       cfbDirEnt("EncryptionInfo", 2, -1, -1, -1, 3, 100)],
      [CfbEnd, CfbEnd, CfbEnd, CfbEnd],
      [@[1'u8, 2, 3], @[4'u8, 5, 6]])
    try:
      discard openXlsxBytes(probe)
      fail()
    except XlsxError as e:
      check "password" in e.msg
    # Same shape without the magic name stays legacy.
    var plain = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("Notes", 2, -1, -1, -1, 2, 100)],
      [CfbEnd, CfbEnd, CfbEnd],
      [@[1'u8, 2, 3]])
    try:
      discard openXlsxBytes(plain)
      fail()
    except XlsxError as e:
      check "legacy" in e.msg
