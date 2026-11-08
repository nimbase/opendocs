# XLSX Styles and Number Formats

Modules: `xlsx/styles.nim`, `xlsx/numfmt.nim`, `xlsx/numfmttok.nim`.

## Stylesheet (`styles.nim`)

- `XlsxFont(name, size, bold, italic, strike, outline, shadow, condense, extend, underline, vertAlign, scheme, charset, family, color: Color)`.
- `XlsxFill(kind, pattern, fgColor, bgColor, gradientColors, gradientType, gradientDegree, shading)`.
- `XlsxBorderSide(style, color)`, `XlsxBorder(left, right, top, bottom, diagonal, vertical, horizontal, diagonalUp/Down, outline)`.
- `XlsxAlignment(horizontal, vertical, wrapText, shrinkToFit, justifyLastLine, indent, relativeIndent, readingOrder, textRotation)`.
- `XlsxProtection(hidden, locked)`.
- `XlsxXf(numFmtId, fontId, fillId, borderId, xfId, apply* + hasApply*, alignment + hasAlignment, protection + hasProtection)`.
- `XlsxStyle(numFmtId, fontId, fillId, borderId, hasFont/font, hasFill/fill, hasBorder/border, hasAlignment/alignment, hasProtection/protection)`.
- `XlsxStylesheet(numFmts: Table[int, string], cellXfs, fonts, fills, borders, indexedColors)`.
- `IndexedColorMapping: array[66, string]`.
- `loadStyles(f)` — eager `xl/styles.xml`, missing -> empty. `numFmtIdFor(st, styleIdx)`, `getStyle(f, idx): XlsxStyle`.

## Number formats (`numfmt.nim`)

- `XlsxFormatInfo(applied, numFmtId, code, builtin, text)`.
- `formatInfo(f, rawV, effType, styleIdx): XlsxFormatInfo`, `formattedCellValue(f, rawV, effType, styleIdx): string`.
- Engine: builtin codes 0-49, `renderDateCode`, accounting sections, custom-code path via `numfmttok`.

## Number format tokens (`numfmttok.nim`)

- `NumFmtPart(kind, value)`, `NumFmtToken(kind, text, quoted, escaped, marker, parts)`, `NumFmtSection(kind, items)`, `NumFmtAst(ok, sections)`.
- `parseNumFmt(code): NumFmtAst`, `renderNumFmtToken(t): string`, `renderNumFmt(ast): string`.

Locale: `XlsxLocale(tags, monthsFull/Abbrev/Narrow[12], weekdaysFull[7]/Abbrev[7], apFmt, useGannen)` in `types.nim`.

Tests: `t_xlsx_numfmt_tok.nim`, `t_xlsx_numfmt_custom.nim`, `t_xlsx_oracle.nim` (576-cell parity), generators `gen_xlsx_numfmt.nim`, `gen_xlsx_style.nim`, `gen_xlsx_richtext.nim`.
