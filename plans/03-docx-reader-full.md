# docx full reader — build plan (locked)

Decisions: blocks-in-cells (breaking), full Drawing table, filter field
instructions. `w:br` page → `\f`, column/textWrapping → `\n`.

## P1 — Run properties
Extend `Run`: styleId, caps, smallCaps, vanish, webHidden, vertAlign,
spacingTwips, positionPts, kernHalfPts, shading, outline, shadow, emboss,
imprint, noProof, fitText, bCs/iCs, sizeCsHalfPts, fontsEastAsia/HAnsi,
lang, colorTheme/Shade/Tint, commentRef (-1). `w:val="false"` clears b/i/
strike. Field state machine per paragraph: drop `w:instrText` between
begin/separate, keep cached result after separate.

## P2 — Paragraph properties
Extend `Paragraph`: outlineLvl, keepNext, keepLines, pageBreakBefore,
widowControl, shading, bidi, textAlignment, tabs (`w:tabs/w:tab`),
borders. Shared `BorderEdge{style,sizeEighths,space,color}` +
`Borders{top,left,bottom,right,insideH,insideV}` reused by P3.

## P3 — Tables, true nesting (breaking)
`TableCell.paragraphs` → `blocks: seq[Block]`; nested `w:tbl` → bkTable.
`DocxTable` += styleId/width/widthType/align/look/borders/shading/
cellSpacing/layout/grid. New `TableRow{cells,height,heightRule,isHeader,
cantSplit}`. `TableCell` += width/widthType/vAlign/borders. Update
flatText + old tests.

## P4 — Drawings + textboxes
`Drawing{rid,placement,cxEmu,cyEmu,name,descr,behindDoc,posHFrom,posVFrom}`,
`doc.drawings: Table[rid,Drawing]`; `Run.drawingRid` stays key.
`mc:AlternateContent` → first `mc:Choice`, skip Fallback. Textbox paths
(`wps:txbx`, `v:textbox`) → `BlockKind bkTextbox`, `Textbox{blocks}`.

## P5 — Numbering
`NumberingLevel` += start/suffix/justification. `w:lvlOverride`:
empty = inherit; child `w:lvl` = full replacement; `w:startOverride` =
start only.

## P6 — Styles + theme
`StyleInfo` += basedOn/next/qFormat/isDefault/link. `themeColors`
from `word/theme/theme1.xml`; `effectiveColor(run, theme)` with ECMA
shade/tint blending. No latent expansion, no effective-format
computation (explicit non-goals).

## P7 — Sections + getters
`w:pPr/w:sectPr` splits flow into `sections: seq[Section]`; per-section
header/footer resolution; extended `SectionProps` (orient, gutter,
mirrorMargins, header/footer dist, cols, titlePg, pgNumType, docGrid…).
Breaking: header/footer refs move to sections. Getters: `getSections`,
`getSection`, `getPageSettings`, `getHeaders`, `getFooters`.

## P8 — Bookmarks/SDT/props
`doc.bookmarks: seq[Bookmark{id,name}]`; `w:sdt` → `bkSdt`
(`Sdt{alias,tag,blocks}`); app.xml + custom.xml (`vt:` mapping);
skip footnote separator types; tracked-change metadata skipped (noted);
rsid/proofErr/perm ignored (noted).

## P9 — Fixtures + acceptance
Vendor ~15 `.docx` fixtures; no-crash sweep + spot asserts; update
`plans/02-docx-build.md`; green `clue test` per package.
