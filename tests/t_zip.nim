import std/[os, osproc, strutils, tempfiles, unittest]

import ../src/opendocs/zip

func toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

func fromBytes(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

suite "raw deflate helpers":
  test "deflate/inflate round-trip":
    let src = toBytes("hello world, ".repeat(1000))
    let comp = deflateRaw(src)
    check comp.len < src.len
    check inflateRaw(comp) == src

  test "empty payload":
    check inflateRaw(deflateRaw(@[])) == newSeq[byte]()

  test "decompression limit enforced":
    let comp = deflateRaw(toBytes("x".repeat(100000)))
    expect ZipError:
      discard inflateRaw(comp, maxSize = 10)

suite "writer/reader round-trip":
  test "stored + deflated + empty + nested + unicode":
    var w = newZipWriter()
    w.addFile("[Content_Types].xml",
      "<?xml version=\"1.0\"?><Types/>", zmStored)
    w.addFile("word/document.xml",
      "<w:document>" & "lorem ipsum ".repeat(500) & "</w:document>")
    w.addFile("empty.txt", "")
    w.addFile("word/media/img 1.png", @[137'u8, 80, 78, 71])
    w.addFile("rels/", @[])
    let img = w.toBytes()
    let a = openZipBytes(img)
    check a.filenames.len == 5
    check a.readEntry("[Content_Types].xml") ==
      toBytes("<?xml version=\"1.0\"?><Types/>")
    check a.readEntry("word/document.xml") ==
      toBytes("<w:document>" & "lorem ipsum ".repeat(500) & "</w:document>")
    check a.readEntry("empty.txt") == newSeq[byte]()
    check a.readEntry("word/media/img 1.png") == @[137'u8, 80, 78, 71]
    check a.readEntry("rels/") == newSeq[byte]()
    check a.findEntry("nope.txt") < 0
    expect ZipError:
      discard a.readEntry("nope.txt")

  test "file write/read via disk":
    let dir = createTempDir("opendocs_", "_zip")
    defer: removeDir(dir)
    let path = dir / "pkg.zip"
    var w = newZipWriter()
    w.addFile("a.txt", "abc")
    w.writeZip(path)
    let a = openZip(path)
    check fromBytes(a.readEntry("a.txt")) == "abc"

  test "CRC mismatch detected":
    var w = newZipWriter()
    w.addFile("a.txt", "abcdef".toBytes, zmStored) # stored: payload verbatim
    var img = w.toBytes()
    let needle = toBytes("abcdef")
    var patched = false
    for i in 0 .. img.len - needle.len:
      var match = true
      for j in 0 ..< needle.len:
        if img[i + j] != needle[j]:
          match = false
          break
      if match:
        img[i] = img[i] xor 0xFF # corrupt payload byte
        patched = true
        break
    check patched
    let a = openZipBytes(img)
    expect ZipError:
      discard a.readEntry("a.txt")

  test "zip-slip names rejected on write":
    var w = newZipWriter()
    expect ZipError:
      w.addFile("../evil.txt", "x")
    expect ZipError:
      w.addFile("/abs.txt", "x")

  test "zip-slip names rejected on read":
    # hand-built central entry with ../ name must fail parsing
    var w = newZipWriter()
    w.addFile("ok.txt", "x")
    var img = w.toBytes()
    # patch every "ok.txt" occurrence (local + central headers) to "../q.t"
    let needle = toBytes("ok.txt")
    let evil = toBytes("../q.t")
    var patched = 0
    for i in 0 .. img.len - needle.len:
      var match = true
      for j in 0 ..< needle.len:
        if img[i + j] != needle[j]:
          match = false
          break
      if match:
        for j in 0 ..< needle.len: img[i + j] = evil[j]
        inc patched
    check patched == 2
    expect ZipError:
      discard openZipBytes(img)

  test "duplicate entry rejected":
    var w = newZipWriter()
    w.addFile("a.txt", "1")
    expect ZipError:
      w.addFile("a.txt", "2")

  test "truncated input rejected":
    expect ZipError:
      discard openZipBytes(@[1'u8, 2, 3])
    expect ZipError:
      discard openZipBytes(toBytes("PK\x03\x04garbage"))

suite "interop with system zip/unzip":
  test "our output passes `unzip -t`, and we read system zip output":
    let dir = createTempDir("opendocs_", "_interop")
    defer: removeDir(dir)
    var w = newZipWriter()
    w.addFile("[Content_Types].xml", "<Types/>", zmStored)
    w.addFile("word/document.xml",
      "<w:document><w:body><w:p>hi</w:p></w:body></w:document>")
    let ours = dir / "ours.zip"
    w.writeZip(ours)
    let (tOut, tCode) = execCmdEx("unzip -t " & quoteShell(ours))
    check tCode == 0
    check "No errors detected" in tOut
    # other direction: system zip -> our reader
    let sysDir = dir / "sys"
    createDir(sysDir / "word")
    writeFile(sysDir / "[Content_Types].xml", "<Types/>")
    writeFile(sysDir / "word" / "document.xml", "<doc/>")
    let sysZip = dir / "sys.zip"
    let (_, zCode) = execCmdEx("zip -qr " & quoteShell(sysZip) & " .",
      workingDir = sysDir)
    check zCode == 0
    let a = openZip(sysZip)
    check fromBytes(a.readEntry("[Content_Types].xml")) == "<Types/>"
    check fromBytes(a.readEntry("word/document.xml")) == "<doc/>"
