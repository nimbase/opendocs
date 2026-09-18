## Shared model types for Word `.docx` (OOXML WordprocessingML)
## read + write. Owned data throughout (`string`/`seq`/`Table`).

import std/tables

type
  DocxError* = object of CatchableError

  FieldCharKind* = enum
    fckNone ## no w:fldChar in this run
    fckBegin
    fckSeparate
    fckEnd
    fckUnknown ## unrecognized w:fldCharType; source value in fldCharRaw

  FieldInstrKind* = enum
    fikNone ## no w:instrText/w:delInstrText in this run
    fikToc
    fikTc
    fikPage
    fikNumPages
    fikPageRef
    fikHyperlink
    fikUnsupported ## any other instruction; verbatim text in raw

  InstrSwitch* = object ## one `\flag [arg]` switch, e.g. `\o "1-3"`, bare `\h`
    flag*: string
    arg*: string
    hasArg*: bool

  TocInstr* = object
    switches*: seq[InstrSwitch]

  TcInstr* = object
    text*: string
    omitsPageNum*: bool ## \n
    level*: int ## \l N, -1 = absent
    itemId*: string ## \f identifier, "" = absent

  PageRefInstr* = object
    bookmark*: string
    hyperlink*: bool ## \h
    relPos*: bool ## \p

  HyperlinkInstr* = object
    target*: string
    anchor*: bool ## \l

  FieldInstr* = object ## typed view of a field instruction
    case kind*: FieldInstrKind
    of fikNone: discard
    of fikToc: toc*: TocInstr
    of fikTc: tc*: TcInstr
    of fikPage, fikNumPages: discard
    of fikPageRef: pageRef*: PageRefInstr
    of fikHyperlink: hyperlink*: HyperlinkInstr
    of fikUnsupported: raw*: string

  Run* = object
    text*: string
    bold*: bool
    italic*: bool
    underline*: bool
    strike*: bool
    dstrike*: bool ## double strikethrough (independent of strike)
    sizeHalfPts*: int ## 0 = unspecified
    color*: string ## hex RGB, "" = auto/unspecified
    colorTheme*: string ## accent1..6, hyperlink…, "" = none
    colorShade*: string ## 00..FF fraction toward black
    colorTint*: string ## 00..FF fraction toward white
    fonts*: string ## ascii face, "" = unspecified
    fontsEastAsia*: string
    fontsHAnsi*: string
    lang*: string
    highlight*: string
    styleId*: string ## w:rStyle
    vertAlign*: string ## superscript/subscript, "" = baseline
    spacingTwips*: int ## 0 = unspecified
    positionPts*: int ## raised/lowered half-pts, 0 = unspecified
    kernHalfPts*: int ## 0 = unspecified
    shading*: string ## fill hex, "" = none
    caps*: bool
    smallCaps*: bool
    vanish*: bool
    webHidden*: bool
    outline*: bool
    shadow*: bool
    emboss*: bool
    imprint*: bool
    noProof*: bool
    fitText*: bool
    boldCs*: bool
    italicCs*: bool
    sizeCsHalfPts*: int
    hyperlinkRid*: string
    drawingRid*: string
    symFont*: string ## w:sym font, "" = none (glyph lives here, not text)
    symChar*: string ## w:sym hex code, "" = none
    footnoteRef*: int ## -1 = none
    endnoteRef*: int ## -1 = none
    commentRef*: int ## -1 = none
    fldChar*: FieldCharKind ## w:fldChar boundary marker, fckNone = none
    fldCharRaw*: string ## source w:fldCharType when fldChar == fckUnknown
    fldDirty*: bool ## w:dirty on the marker
    fldLock*: bool ## w:fldLock on the marker
    instrRaw*: string ## verbatim w:instrText/w:delInstrText ("" = none)
    instr*: FieldInstr ## typed view of instrRaw (fikNone = none)
    delInstr*: bool ## instruction came from w:delInstrText (inside w:del)
    delText*: string ## w:delText content ("" = none; never with w:t text)
    rIns*: RevisionMeta ## w:rPr/w:ins paragraph-mark insertion
    hasRIns*: bool
    rDel*: RevisionMeta ## w:rPr/w:del paragraph-mark deletion
    hasRDel*: bool
    rPrChange*: PropChange ## w:rPr/w:rPrChange
    hasRPrChange*: bool
    rsidR*: string ## w:rsidR on w:r, "" = absent

  ParaKidKind* = enum
    pkRun
    pkFldSimple ## w:fldSimple: instruction + cached runs
    pkIns ## w:ins tracked insertion
    pkDel ## w:del tracked deletion
    pkMoveFrom ## w:moveFrom tracked move source
    pkMoveTo ## w:moveTo tracked move destination

  RevisionMeta* = object ## shared w:id/w:author/w:date on revisions
    id*: string ## "" = assign from revNextId on write
    author*: string
    date*: string

  RevRun* = object ## one revision wrapper: meta + member runs
    meta*: RevisionMeta
    runs*: seq[Run]

  PropChange* = object ## *PrChange wrapper with verbatim inner XML:
    meta*: RevisionMeta ## rPrChange, tcPrChange, trPrChange,
    rawInner*: string ## tblPrChange, tblGridChange, numberingChange,
                      ## numPrChange, sectPrChange (pPrChange is structured:
                      ## see ParaChange on Paragraph)

  RangeMarkerKind* = enum
    rmkMoveFromStart ## w:moveFromRangeStart
    rmkMoveFromEnd ## w:moveFromRangeEnd
    rmkMoveToStart ## w:moveToRangeStart
    rmkMoveToEnd ## w:moveToRangeEnd
    rmkCustomXml ## w:customXmlInsRangeStart/End, DelRange, MoveFrom/To

  RangeMarker* = object
    kind*: RangeMarkerKind
    tag*: string ## verbatim tag (authoritative for emission)
    name*: string ## w:name (move pairing / customXml item)
    id*: string ## w:id
    uri*: string ## w:uri on customXml markers, "" = absent
    element*: string ## w:element on customXml markers, "" = absent

  ParaChange* = object ## w:pPrChange: meta + replaced paragraph props
    meta*: RevisionMeta
    ppr*: ref Paragraph ## inner w:pPr content (kids always empty)

  FldSimple* = object
    instrRaw*: string ## verbatim w:instr attribute
    instr*: FieldInstr ## typed view
    runs*: seq[Run]

  ParaKid* = object
    case kind*: ParaKidKind
    of pkRun: run*: Run
    of pkFldSimple: fld*: FldSimple
    of pkIns, pkDel, pkMoveFrom, pkMoveTo: rev*: RevRun

  Paragraph* = object
    styleId*: string
    align*: string ## left/center/right/both/distribute, "" = unspecified
    numId*: int ## -1 = no numbering
    numIlvl*: int
    indentLeft*: int ## twips, -1 = unspecified
    indentFirstLine*: int ## twips, -1 = unspecified
    spacingBefore*: int ## twips, -1 = unspecified
    spacingAfter*: int ## twips, -1 = unspecified
    outlineLvl*: int ## 0-8 heading level, -1 = body text
    keepNext*: bool
    keepLines*: bool
    pageBreakBefore*: bool
    widowControl*: bool
    shading*: string ## fill hex, "" = none
    bidi*: bool
    textAlignment*: string
    tabs*: seq[TabStop]
    borders*: Borders
    bookmarks*: seq[Bookmark] ## bookmarkStarts among children
    kids*: seq[ParaKid] ## runs, fields, revision wrappers in doc order
    pPrIns*: RevisionMeta ## w:pPr/w:ins paragraph-mark insertion
    hasPPrIns*: bool
    pPrDel*: RevisionMeta ## w:pPr/w:del paragraph-mark deletion
    hasPPrDel*: bool
    pPrChange*: ParaChange ## w:pPr/w:pPrChange
    hasPPrChange*: bool
    numPrChange*: PropChange ## w:pPr/w:numPr/w:numPrChange
    hasNumPrChange*: bool
    rsidR*: string ## w:rsidR on w:p, "" = absent
    rsidP*: string ## w:rsidP on w:pPr, "" = absent
    rsidRPr*: string ## w:rsidRPr on w:pPr, "" = absent
    rsidDel*: string ## w:rsidDel on w:pPr, "" = absent
    rangeMarkers*: seq[RangeMarker] ## move/customXml range markers

  TableCell* = object
    blocks*: seq[Block]
    gridSpan*: int
    vMerge*: string ## "", "restart", "continue"
    shading*: string ## fill hex, "" = none
    width*: int ## -1 = unspecified
    widthType*: string ## dxa/pct/auto/nil
    vAlign*: string ## top/center/bottom
    borders*: Borders
    tcIns*: RevisionMeta ## w:tcPr/w:cellIns
    hasTcIns*: bool
    tcDel*: RevisionMeta ## w:tcPr/w:cellDel
    hasTcDel*: bool
    tcMerge*: RevisionMeta ## w:tcPr/w:cellMerge
    hasTcMerge*: bool
    tcPrChange*: PropChange ## w:tcPr/w:tcPrChange
    hasTcPrChange*: bool

  TableRow* = object
    cells*: seq[TableCell]
    height*: int ## twips, 0 = auto
    heightRule*: string ## atLeast/exact/auto
    isHeader*: bool
    cantSplit*: bool
    trIns*: RevisionMeta ## w:trPr/w:ins
    hasTrIns*: bool
    trDel*: RevisionMeta ## w:trPr/w:del
    hasTrDel*: bool
    trPrChange*: PropChange ## w:trPr/w:trPrChange
    hasTrPrChange*: bool

  DocxTable* = object
    rows*: seq[TableRow]
    styleId*: string
    width*: int ## -1 = unspecified
    widthType*: string
    align*: string
    look*: string
    borders*: Borders
    shading*: string
    cellSpacing*: int ## twips, -1 = unspecified
    cellSpacingType*: string
    layout*: string ## fixed/autofit
    grid*: seq[int] ## column widths, twips
    tblPrChange*: PropChange ## w:tblPr/w:tblPrChange
    hasTblPrChange*: bool
    tblGridChange*: PropChange ## w:tblGrid/w:tblGridChange
    hasTblGridChange*: bool

  BlockKind* = enum
    bkParagraph
    bkTable
    bkTextbox
    bkSdt
    bkIns ## body-level w:ins around blocks
    bkDel ## body-level w:del around blocks

  RevBlock* = object ## one body-level revision wrapper
    meta*: RevisionMeta
    blocks*: seq[Block]

  Textbox* = object
    blocks*: seq[Block]
    cxEmu*: int ## shape width, EMU (0 = unknown)
    cyEmu*: int ## shape height, EMU (0 = unknown)

  DrawingPlacement* = enum
    dpInline
    dpAnchor

  Drawing* = object
    relId*: string
    placement*: DrawingPlacement
    cxEmu*: int
    cyEmu*: int
    name*: string
    descr*: string
    behindDoc*: bool
    posHFrom*: string
    posVFrom*: string

  Sdt* = object ## structured document tag (content control)
    alias*: string
    tag*: string
    blocks*: seq[Block]

  Block* = object
    case kind*: BlockKind
    of bkParagraph: paragraph*: Paragraph
    of bkTable: table*: DocxTable
    of bkTextbox: textbox*: Textbox
    of bkSdt: sdt*: Sdt
    of bkIns, bkDel: rev*: RevBlock

  BorderEdge* = object
    style*: string ## single/dashed/nil/… "" = none
    sizeEighths*: int
    space*: int ## points
    color*: string

  Borders* = object
    top*: BorderEdge
    left*: BorderEdge
    bottom*: BorderEdge
    right*: BorderEdge
    insideH*: BorderEdge
    insideV*: BorderEdge

  TabStop* = object
    kind*: string ## left/center/right/decimal/bar/clear/num
    pos*: int ## twips

  StyleInfo* = object
    name*: string
    kind*: string ## paragraph/character/table/numbering
    basedOn*: string
    next*: string
    link*: string
    qFormat*: bool
    isDefault*: bool
    custom*: bool ## w:customStyle (user-defined, not built-in)
    pPr*: Paragraph ## style paragraph formatting (styleId/numId/runs unused)
    hasPPr*: bool
    rPr*: Run ## style run formatting (text/refs/drawing unused)
    hasRPr*: bool
    tblPrRaw*: string ## verbatim w:tblPr inner XML (table styles)

  NumberingLevel* = object
    ilvl*: int
    format*: string ## bullet/decimal/...
    text*: string
    start*: int
    suffix*: string ## tab/space/nothing
    justification*: string
    indentLeft*: int ## twips, -1 = unspecified (from w:lvl/w:pPr/w:ind)
    indentHanging*: int ## twips, -1 = unspecified
    indentRight*: int ## twips, -1 = unspecified
    indentFirstLine*: int ## twips, -1 = unspecified
    indentLeftChars*: int ## -1 = unspecified (w:leftChars, 1/100 char)
    indentHangingChars*: int ## -1 = unspecified
    indentFirstLineChars*: int ## -1 = unspecified
    pPrJc*: string ## w:lvl/w:pPr/w:jc, "" = none
    tabs*: seq[TabStop] ## w:lvl/w:pPr/w:tabs
    lvlRPr*: Run ## w:lvl/w:rPr (text/refs/drawing unused)
    hasLvlRPr*: bool ## distinguish empty <w:rPr/> from absent
    pStyle*: string ## w:lvl/w:pStyle, "" = none
    lvlRestart*: int ## w:lvlRestart override level, -1 = none
    isLgl*: bool ## w:isLgl (legal numbering)
    legacyVal*: int ## w:legacy @w:val, -1 = absent
    legacySpace*: int ## w:legacy @w:space, -1 = absent
    legacyIndent*: int ## w:legacy @w:legacyIndent, -1 = absent

  NumOverride* = object ## one w:lvlOverride: replacement level and/or
    ilvl*: int ##   start override (caller-supplied numbering defs)
    hasLevel*: bool
    level*: NumberingLevel
    startOverride*: int ## -1 = none

  NumberingDef* = object ## one w:num: abstract reference + overrides
    numId*: int
    abstractId*: int
    levels*: seq[NumberingLevel] ## abstract levels (pre-override)
    overrides*: seq[NumOverride]
  CoreProps* = object
    title*: string
    author*: string
    created*: string
    modified*: string

  HeaderFooter* = object
    refKind*: string ## default/first/even
    blocks*: seq[Block]

  Footnote* = object
    id*: int
    blocks*: seq[Block]

  DocComment* = object
    id*: int
    author*: string
    date*: string
    initials*: string
    blocks*: seq[Block]

  SectionProps* = object
    pgW*: int
    pgH*: int
    orient*: string
    marginTop*: int
    marginRight*: int
    marginBottom*: int
    marginLeft*: int
    headerDist*: int
    footerDist*: int
    gutter*: int
    mirrorMargins*: bool
    colsNum*: int
    colsSpace*: int
    titlePg*: bool
    pgNumFmt*: string
    pgNumStart*: int ## -1 = unspecified
    sectType*: string ## nextPage/continuous/evenPage/oddPage/nextColumn
    linePitch*: int ## -1 = unspecified
    textDirection*: string
    sectPrChange*: PropChange ## w:sectPr/w:sectPrChange
    hasSectPrChange*: bool

  SectionRef* = object
    refKind*: string ## default/first/even
    relId*: string

  Section* = object
    blocks*: seq[Block]
    props*: SectionProps
    headerRefs*: seq[SectionRef]
    footerRefs*: seq[SectionRef]
    headers*: seq[HeaderFooter]
    footers*: seq[HeaderFooter]

  Bookmark* = object
    id*: int
    name*: string

  AppProps* = object
    application*: string
    templateName*: string
    pages*: int
    words*: int
    characters*: int
    paragraphs*: int

  CustomValueKind* = enum
    cvkString ## vt:lpwstr/lpstr/bstr
    cvkInt ## vt:i1/i2/i4/i8/int/uint and unsigned family
    cvkBool ## vt:bool
    cvkFloat ## vt:r4/r8/decimal
    cvkDate ## vt:filetime/date, kept as ISO-8601 string
    cvkRaw ## any other vt:* — tag + text preserved verbatim

  CustomValue* = object
    case kind*: CustomValueKind
    of cvkString: str*: string
    of cvkInt: num*: int64
    of cvkBool: b*: bool
    of cvkFloat: f*: float64
    of cvkDate: iso*: string
    of cvkRaw:
      tag*: string
      text*: string

  CustomProp* = object
    name*: string
    value*: CustomValue

func customStr*(s: string): CustomValue =
  CustomValue(kind: cvkString, str: s)

func customInt*(n: int64): CustomValue =
  CustomValue(kind: cvkInt, num: n)

func customBool*(b: bool): CustomValue =
  CustomValue(kind: cvkBool, b: b)

func customFloat*(f: float64): CustomValue =
  CustomValue(kind: cvkFloat, f: f)

func customDate*(iso: string): CustomValue =
  CustomValue(kind: cvkDate, iso: iso)

func `$`*(v: CustomValue): string =
  ## Display form (string content unwrapped, numbers rendered plainly).
  case v.kind
  of cvkString: v.str
  of cvkInt: $v.num
  of cvkBool: $v.b
  of cvkFloat: $v.f
  of cvkDate: v.iso
  of cvkRaw: v.text

func `==`*(a, b: CustomValue): bool =
  ## Structural equality (case objects get none from the compiler).
  if a.kind != b.kind: return false
  case a.kind
  of cvkString: a.str == b.str
  of cvkInt: a.num == b.num
  of cvkBool: a.b == b.b
  of cvkFloat: a.f == b.f
  of cvkDate: a.iso == b.iso
  of cvkRaw: a.tag == b.tag and a.text == b.text

func `==`*(a, b: FieldInstr): bool =
  ## Structural equality (case objects get none from the compiler).
  if a.kind != b.kind: return false
  case a.kind
  of fikNone, fikPage, fikNumPages: true
  of fikToc: a.toc.switches == b.toc.switches
  of fikTc:
    a.tc.text == b.tc.text and a.tc.omitsPageNum == b.tc.omitsPageNum and
    a.tc.level == b.tc.level and a.tc.itemId == b.tc.itemId
  of fikPageRef:
    a.pageRef.bookmark == b.pageRef.bookmark and
    a.pageRef.hyperlink == b.pageRef.hyperlink and
    a.pageRef.relPos == b.pageRef.relPos
  of fikHyperlink:
    a.hyperlink.target == b.hyperlink.target and
    a.hyperlink.anchor == b.hyperlink.anchor
  of fikUnsupported: a.raw == b.raw

func `==`*(a, b: ParaKid): bool =
  ## Structural equality (case objects get none from the compiler).
  if a.kind != b.kind: return false
  case a.kind
  of pkRun: a.run == b.run
  of pkFldSimple:
    a.fld.instrRaw == b.fld.instrRaw and a.fld.instr == b.fld.instr and
    a.fld.runs == b.fld.runs
  of pkIns, pkDel, pkMoveFrom, pkMoveTo:
    a.rev.meta == b.rev.meta and a.rev.runs == b.rev.runs

func `==`*(a, b: ParaChange): bool =
  ## Structural equality over the indirection (`ref` compares identity).
  if a.meta != b.meta: return false
  if a.ppr.isNil and b.ppr.isNil: return true
  if a.ppr.isNil or b.ppr.isNil: return false
  a.ppr[] == b.ppr[]

func pkRun*(r: Run): ParaKid =
  ## Wrap a run as a paragraph child.
  ParaKid(kind: pkRun, run: r)

func runs*(p: Paragraph): seq[Run] =
  ## Plain runs among children (simple-field cached runs excluded).
  for k in p.kids:
    if k.kind == pkRun: result.add k.run

type
  DocxDocument* = object
    blocks*: seq[Block] ## full flat flow (concat of all sections)
    sections*: seq[Section]
    footnotes*: seq[Footnote]
    endnotes*: seq[Footnote]
    comments*: seq[DocComment]
    styles*: Table[string, StyleInfo]
    numbering*: Table[int, seq[NumberingLevel]]
    numberingDefs*: seq[NumberingDef] ## caller-supplied w:num definitions
    hyperlinks*: Table[string, string] ## relId -> target
    images*: seq[tuple[relId, contentType: string, data: seq[byte]]]
    drawings*: Table[string, Drawing] ## relId -> geometry
    themeColors*: Table[string, string] ## accent1.. -> RRGGBB
    coreProps*: CoreProps
    appProps*: AppProps
    customProps*: seq[CustomProp]
    bookmarks*: seq[Bookmark]
    sdts*: seq[Sdt]
    rawParts*: Table[string, seq[byte]]
    revNextId*: int ## next w:id for freshly built revisions (0 = unset)

const
  DefaultSpillThresholdBytes* = 64 * 1024 * 1024
    ## Spill parts to temp files when total inflated size exceeds this.
  DefaultSpillCapBytes* = 512 * 1024 * 1024
    ## Hard cap on total bytes spilled to disk (zip-bomb guard).

type
  DocxReadOpts* = object
    spillThresholdBytes*: int = DefaultSpillThresholdBytes
      ## >0: spill when total inflated size exceeds it; 0: always spill;
      ## <0: never spill (pure in-memory).
    spillCapBytes*: int = DefaultSpillCapBytes
      ## Total spilled bytes allowed (<=0 selects the default cap).
    spillDir*: string = ""
      ## Parent for the spill dir ("" = system temp dir).
