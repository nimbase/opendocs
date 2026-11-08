## Document metadata (ISO 32000 §14.3): /Info dictionary + XMP packet.
##
## docInfo reads /Info from the newest trailer (resolve decrypts it like
## any other strings) and the catalog's /Metadata stream for the raw XMP
## packet plus three shallow convenience fields. XMP parsing uses
## openparser's DOM and never becomes an RDF engine: dc:title honours
## rdf:Alt (x-default first), dc:creator takes the first rdf:Seq/Bag li,
## xmp:CreateDate is plain text; anything unparseable yields "" while
## the raw packet stays available. Dates parse the D:YYYY... grammar
## alongside the raw string; malformed dates are ok=false, never guessed.

import std/strutils
import std/tables
import openparser/xml
import ./cos
import ./filters
import ./docmodel

type
  PdfDate* = object
    ok*: bool
    year*, month*, day*, hour*, minute*, second*: int
    tzHour*, tzMinute*: int ## UTC offset (Z or absent reads 0/0)

  PdfInfo* = object
    title*, author*, subject*, keywords*, creator*, producer*: string
    creationDate*, modDate*: string ## raw PDF date strings
    created*, modified*: PdfDate ## parsed (ok=false when absent/malformed)
    trapped*: string ## /True /False /Unknown, "" when absent
    xmp*: string ## raw /Metadata packet, "" when absent
    xmpTitle*, xmpCreator*, xmpCreateDate*: string ## convenience, "" when absent

proc decodeTextString*(s: string): string =
  ## Text-string bytes to Unicode: UTF-16BE with BOM decodes, anything
  ## else passes through (PDFDocEncoding vs WinAnsi differ only in a few
  ## code points; guessing wrongly is worse than passing through).
  if s.len >= 2 and byte(s[0]) == 0xFE and byte(s[1]) == 0xFF:
    result = ""
    var i = 2
    while i + 1 < s.len:
      let cp = int(byte(s[i])) * 256 + int(byte(s[i + 1]))
      i += 2
      if cp < 0x80:
        result.add(char(cp))
      elif cp < 0x800:
        result.add(char(0xC0 or (cp shr 6)))
        result.add(char(0x80 or (cp and 0x3F)))
      elif cp >= 0xD800 and cp <= 0xDBFF and i + 1 < s.len:
        let lo = int(byte(s[i])) * 256 + int(byte(s[i + 1]))
        if lo >= 0xDC00 and lo <= 0xDFFF:
          let full = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          i += 2
          result.add(char(0xF0 or (full shr 18)))
          result.add(char(0x80 or ((full shr 12) and 0x3F)))
          result.add(char(0x80 or ((full shr 6) and 0x3F)))
          result.add(char(0x80 or (full and 0x3F)))
        else:
          result.add("\xEF\xBF\xBD")
      else:
        result.add(char(0xE0 or (cp shr 12)))
        result.add(char(0x80 or ((cp shr 6) and 0x3F)))
        result.add(char(0x80 or (cp and 0x3F)))
  else:
    result = s

proc infoString(info: CosObj, key: string): string =
  let v = info.dictGet(key)
  if v.kind == coStr:
    return decodeTextString(v.sval)
  if v.kind == coName:
    return v.name
  ""

proc parsePdfDate*(s: string): PdfDate =
  ## D:YYYY[MM[DD[HH[mm[SS[O[HH'[mm']]]]]]]] with PDF defaults
  ## (month/day 1, time 0). Anything malformed is ok=false.
  result = PdfDate(ok: false, month: 1, day: 1)
  var t = s
  if t.startsWith("D:"):
    t = t[2 .. ^1]
  if t.len < 4:
    return
  for c in t[0 ..< 4]:
    if c notin {'0'..'9'}: return
  try:
    result.year = parseInt(t[0 ..< 4])
  except ValueError:
    return
  var pos = 4
  proc take(n: int, dflt: int): int =
    if pos + n <= t.len:
      var ok = true
      for c in t[pos ..< pos + n]:
        if c notin {'0'..'9'}: ok = false
      if ok:
        try:
          let v = parseInt(t[pos ..< pos + n])
          pos += n
          return v
        except ValueError:
          discard
    dflt
  result.month = take(2, 1)
  result.day = take(2, 1)
  result.hour = take(2, 0)
  result.minute = take(2, 0)
  result.second = take(2, 0)
  if result.month < 1 or result.month > 12 or result.day < 1 or
      result.day > 31 or result.hour > 23 or result.minute > 59 or
      result.second > 60:
    return
  if pos < t.len:
    let o = t[pos]
    if o == 'Z':
      pos += 1
    elif o == '+' or o == '-':
      let sign = if o == '+': 1 else: -1
      pos += 1
      let oh = take(2, -1)
      if oh < 0 or oh > 23: return
      result.tzHour = sign * oh
      if pos < t.len and t[pos] == '\'':
        pos += 1
        let om = take(2, -1)
        if om < 0 or om > 59: return
        result.tzMinute = sign * om
        if pos < t.len and t[pos] == '\'':
          pos += 1
    else:
      return
  if pos != t.len:
    return
  result.ok = true

proc localName(tag: string): string =
  let k = tag.rfind(':')
  if k < 0: tag else: tag[k + 1 .. ^1]

proc elementText(n: XmlNode): string =
  if n.kind != xnElement: return ""
  for c in n.children:
    if c.kind == xnText:
      result.add(c.text)

proc xmpAlt(n: XmlNode): string =
  ## rdf:Alt: the x-default li, else the first li.
  var first = ""
  for c in n.children:
    if c.kind == xnElement and localName(c.tag) == "li":
      let lang = c.attrs.getOrDefault("xml:lang", "")
      let t = elementText(c).strip()
      if first.len == 0: first = t
      if lang == "x-default": return t
  first

proc xmpSeq(n: XmlNode): string =
  ## rdf:Seq/Bag: the first li.
  for c in n.children:
    if c.kind == xnElement and localName(c.tag) == "li":
      return elementText(c).strip()
  ""

proc xmpFieldValue(n: XmlNode): string =
  ## The property element's value honoring Alt/Seq/Bag wrappers.
  for c in n.children:
    if c.kind == xnElement:
      case localName(c.tag)
      of "Alt": return xmpAlt(c)
      of "Seq", "Bag": return xmpSeq(c)
      else: discard
  elementText(n).strip()

proc findXmp(node: XmlNode, local: string): string =
  if node.kind != xnElement: return ""
  if localName(node.tag) == local:
    let v = xmpFieldValue(node)
    if v.len > 0: return v
  for c in node.children:
    let v = findXmp(c, local)
    if v.len > 0: return v
  ""

proc xmpField*(packet, local: string): string =
  ## Shallow XMP convenience read (Alt/Seq/Bag aware). "" when the
  ## packet is absent, unparseable, or lacks the property.
  if packet.len == 0: return ""
  try:
    findXmp(fromXml(packet), local)
  except CatchableError:
    ""

proc docInfo*(d: var PdfDoc): PdfInfo =
  ## /Info strings plus the catalog's XMP packet. Absent keys read "",
  ## malformed dates parse as ok=false, unparseable XMP keeps raw bytes
  ## with empty convenience fields.
  var info = d.xref.info
  if info.kind == coRef:
    info = d.resolve(info)
  if info.kind == coDict:
    result.title = infoString(info, "Title")
    result.author = infoString(info, "Author")
    result.subject = infoString(info, "Subject")
    result.keywords = infoString(info, "Keywords")
    result.creator = infoString(info, "Creator")
    result.producer = infoString(info, "Producer")
    result.creationDate = infoString(info, "CreationDate")
    result.modDate = infoString(info, "ModDate")
    let tr = info.dictGet("Trapped")
    if tr.kind == coName:
      result.trapped = tr.name
  result.created = parsePdfDate(result.creationDate)
  result.modified = parsePdfDate(result.modDate)
  var meta = d.catalog().dictGet("Metadata")
  if meta.kind == coRef:
    meta = d.resolve(meta)
  if meta.kind == coStream:
    result.xmp = decodeCosStream(meta, d.limits)
    result.xmpTitle = xmpField(result.xmp, "title")
    result.xmpCreator = xmpField(result.xmp, "creator")
    result.xmpCreateDate = xmpField(result.xmp, "CreateDate")
