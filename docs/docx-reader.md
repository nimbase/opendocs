# DOCX Reader

Entry: `src/opendocs/docx.nim` re-exports `docx/core` (`include types; reader; writer`). All reader symbols live in `src/opendocs/docx/reader.nim` and getters in `src/opendocs/docx/core.nim`.

## Opening

```nim
let doc = readDocx("report.docx")
let doc2 = readDocx("huge.docx", DocxReadOpts(
  spillThresholdBytes: 64 * 1024 * 1024,
  spillCapBytes: 512 * 1024 * 1024))
let doc3 = readDocxBytes(bytes)
```

- `readDocx(path, opts): DocxDocument` — `reader.nim:1339`, file wrapper.
- `readDocxBytes(data, opts): DocxDocument` — `reader.nim:1178`, from memory.
- Requires `word/document.xml`. Interprets styles, numbering, rels, media, headers, footers, footnotes, endnotes, comments, theme, core/app/custom props. Unknown parts preserved byte-exact in `rawParts`.
- Raises `DocxError` (object of `CatchableError`, `types.nim:7`) on non-zip, bad XML (strict), missing document, missing image target, dangling section refs, wrong roots.
- Spill: inflated part size > `spillThresholdBytes` spills to temp + mmap. `0` forces spill (testing), `<0` disables. `spillCapBytes` is hard disk-use cap. `spillDir = ""` means system temp.

Options (`types.nim:570`):

- `DocxReadOpts(spillThresholdBytes, spillCapBytes, spillDir)`
- Defaults: `DefaultSpillThresholdBytes = 64 MiB`, `DefaultSpillCapBytes = 512 MiB`.

## Document model (`types.nim`)

Root: `DocxDocument` (`types.nim:542`):

- `blocks` — flat flow concat of sections
- `sections: seq[Section]`, `footnotes`, `endnotes`, `comments`
- `styles: Table[string, StyleInfo]`, `numbering: Table[int, seq[NumberingLevel]]`, `numberingDefs: seq[NumberingDef]`
- `hyperlinks: Table[relId, target]`, `images: seq[(relId, contentType, data)]`, `drawings: Table[relId, Drawing]`
- `themeColors: Table[string, string]` (accent1.. -> RRGGBB)
- `coreProps: CoreProps`, `appProps: AppProps`, `customProps: seq[CustomProp]`
- `bookmarks`, `sdts`, `rawParts: Table[string, seq[byte]]`, `revNextId`

Blocks (`BlockKind`: `bkParagraph, bkTable, bkTextbox, bkSdt, bkIns, bkDel`):

- `Block` variant: `bkParagraph: paragraph`, `bkTable: table`, `bkTextbox: textbox`, `bkSdt: sdt`, `bkIns/bkDel: rev: RevBlock`.
- `Paragraph`: style, align, numId/numIlvl, indents, spacing, tabs, borders, `kids: seq[ParaKid]`, bookmarks, revision marks (`hasPPrIns/Del/Change`, `pPrChange`, `numPrChange`), rsids, `rangeMarkers`.
- `ParaKidKind`: `pkRun, pkFldSimple, pkIns, pkDel, pkMoveFrom, pkMoveTo`. `ParaKid` variant holds `run`, `fld: FldSimple`, or `rev: RevRun`.
- `Run` (`types.nim:59`): full `w:r` model — text, bold/italic/underline/strike/dstrike, sizeHalfPts, color/colorTheme/shade/tint, fonts, lang, highlight, styleId, vertAlign, spacing, shading, caps, vanish, hyperlinkRid, drawingRid, sym, field chars (`fldChar`, `fldDirty`, `fldLock`, `instrRaw`, `instr`, `delInstr`, `delText`), revision ids (`rIns/rDel`), `rsidR`.
- `TableCell`: blocks, gridSpan, vMerge, shading, width, vAlign, borders, revision flags. `TableRow`: cells, height, isHeader, cantSplit. `DocxTable`: rows, style, width, align, borders, grid.
- `Textbox(blocks, cxEmu, cyEmu)`, `Sdt(alias, tag, blocks)`, `Drawing(relId, placement, cxEmu/cyEmu, name, descr, ...)`, `DrawingPlacement(dpInline/dpAnchor)`.
- `Section(blocks, props, headerRefs/footerRefs, headers/footers)`, `SectionProps(pgW/pgH/orient, margins, headerDist/footerDist, cols, titlePg, pgNumFmt/Start, sectType, ...)`, `HeaderFooter(refKind, blocks)`, `Footnote(id, blocks)`, `DocComment(id, author, date, initials, blocks)`.
- Styles: `StyleInfo(name, kind, basedOn, next, link, qFormat, isDefault, custom, pPr, rPr, tblPrRaw)`.
- Numbering: `NumberingLevel(ilvl, format, text, start, suffix, justification, indents, ...)`, `NumberingDef(numId, abstractId, levels, overrides)`, `NumOverride`.
- Props: `CoreProps(title, author, created, modified)`, `AppProps(application, templateName, pages, words, characters, paragraphs)`, `CustomProp(name, value)`, `CustomValue` variant (`cvkString/cvkInt/cvkBool/cvkFloat/cvkDate/cvkRaw`) with constructors `customStr/customInt/customBool/customFloat/customDate`.

## View helpers (`core.nim`)

- `effectiveColor(run, theme): string` (`core.nim:15`) — explicit color wins, else theme + shade/tint blend. `""` if none.
- `flatText(doc): string` (`core.nim:67`) — accept-changes view, paragraphs joined `\n`, tables cell-by-cell. Keeps `ins/moveTo` + `fldSimple` cached, drops `del/moveFrom` + `bkDel`. Instruction text never included.
- `getSections(doc): seq[Section]` (`core.nim:75`), `getSection(doc, i)` with range check.
- `getPageSettings(doc, sectionIdx = -1): SectionProps` — `-1` = last.
- `getHeaders(doc, sectionIdx = -1, kind = "")`, `getFooters(...)` — `kind` filters `default/first/even`, `""` = all.
- `runs(p): seq[Run]` (`types.nim:536`) — plain `pkRun` runs only; most code walks `kids` directly for accept-view.
- `pkRun(r): ParaKid` constructor.

## Fields

- `FieldCharKind(fckNone/Begin/Separate/End/Unknown)`, `FieldInstrKind(fikNone/Toc/Tc/Page/NumPages/PageRef/Hyperlink/Unsupported)`.
- `InstrSwitch(flag, arg, hasArg)`, `TocInstr(switches)`, `TcInstr(text, omitsPageNum, level, itemId)`, `PageRefInstr(bookmark, hyperlink, relPos)`, `HyperlinkInstr(target, anchor)`, `FieldInstr` variant + `FldSimple(instrRaw, instr, runs)`.
- `parseInstr(raw): FieldInstr` (`reader.nim:257`) — typed view of `w:instrText`. Tested in `t_docx_write.nim:318`.

## Examples

See `examples/docx_read_example.nim` — walks blocks, sections, page settings, headers/footers, `effectiveColor`, numbering, styles, theme, hyperlinks, images, drawings, footnotes, comments, bookmarks, sdts, core/app/custom, rawParts. See also `examples/docx_perf.nim` for spill/benchmark harness.
