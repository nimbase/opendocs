# DOCX Revisions and Fields

## Tracked changes

Model:

- Paragraph children: `pkIns/pkDel/pkMoveFrom/pkMoveTo: RevRun(meta, runs)` with `RevisionMeta(id, author, date)`.
- Body blocks: `bkIns/bkDel: RevBlock(meta, blocks)`.
- Property changes: `PropChange(meta, rawInner)` for `rPrChange, tcPrChange, trPrChange, tblPrChange, tblGridChange, numberingChange, numPrChange, sectPrChange`; `ParaChange(meta, ppr: ref Paragraph)` for `pPrChange`.
- Range markers: `RangeMarker(kind, tag, name, id, uri, element)` for move/customXml ranges.

API (`src/opendocs/docx.nim:196-373`):

```nim
acceptAllRevisions(doc)
rejectAllRevisions(doc)
```

- `acceptAllRevisions` — keep `pkIns/pkMoveTo` runs + `bkIns` blocks (unwrapped, marks cleared), drop `pkDel/pkMoveFrom` + `bkDel`, clear `hasRIns/RDel/RPrChange, hasPPrIns/Del/Change, hasNumPrChange, rangeMarkers, hasTbl/Tr/Tc*Change, hasSectPrChange`. Rebuilds `doc.blocks`.
- `rejectAllRevisions` — drop `pkIns/pkMoveTo` + `bkIns`, restore `pkDel/pkMoveFrom -> pkRun` (`delText -> text`), restore `pPr` from `pPrChange.ppr`, clear marks. Rebuilds `doc.blocks`.

`flatText` shows accept-view: keeps ins/moveTo, drops del/moveFrom.

Covered in `tests/t_docx_write.nim` (round-trips, ids, dup detection) and `tests/t_docx_builder.nim`.

## Typed fields

- `parseInstr(raw): FieldInstr` and `serializeInstr(instr): string` round-trip `TOC`, `TC`, `PAGE`, `NUMPAGES`, `PAGEREF`, `HYPERLINK`; else `fikUnsupported(raw)`.
- Simple fields: `FldSimple(instrRaw, instr, runs)` for `w:fldSimple`.
- Complex fields use `Run.fldChar (Begin/Separate/End)`, `instrRaw/instr`, `fldDirty/fldLock`, `delInstr`.
- Validation fails on unbalanced `fldChar`.
- Instruction text never appears in `flatText`.
