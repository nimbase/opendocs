## Stylesheet: eager parse of `xl/styles.xml` for value formatting.
## Ports of excelize `stylesReader` (missing part -> empty, never an
## error) and the `formattedValue` stylesheet half (custom codes plus
## the `cellXfs` number-format index).

proc loadStyles*(f: XlsxFile) =
  ## Eager stylesheet load at open. Only `numFmts` and `cellXfs` are
  ## modeled; fonts/fills/borders/alignment land in Phase C.
  f.styles = XlsxStylesheet()
  let root = readXmlPart(f, "xl/styles.xml")
  if root == nil: return
  if localName(root.tag) != "styleSheet":
    raise newException(XlsxError,
      "xl/styles.xml root is <" & root.tag & ">, want <styleSheet>")
  let nf = firstChildL(root, "numFmts")
  if nf != nil:
    for n in childElemsL(nf, "numFmt"):
      let code = optAttr(n, "formatCode")
      if code != "":
        f.styles.numFmts[intAttr(n, "numFmtId", -1)] = code
  let xfs = firstChildL(root, "cellXfs")
  if xfs != nil:
    for x in childElemsL(xfs, "xf"):
      f.styles.cellXfs.add intAttr(x, "numFmtId", 0)

proc numFmtIdFor*(st: XlsxStylesheet, styleIdx: int): int =
  ## Number-format id for a cell style index, or -1 for the raw-value
  ## fallback (`S<=0`, matching excelize `formattedValue`, or out of
  ## range, where excelize returns the value with a nil error).
  if styleIdx <= 0 or styleIdx >= st.cellXfs.len: return -1
  st.cellXfs[styleIdx]
