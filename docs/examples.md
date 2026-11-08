# Examples

All in `examples/`:

- `docx_read_example.nim` — reader showcase: `readDocx/flatText/getSections/getPageSettings/getHeaders/getFooters/effectiveColor`, walks `bkParagraph/bkTable/bkTextbox/bkSdt/bkIns/bkDel`, numbering/styles/theme/hyperlinks/images/drawings/footnotes/endnotes/comments/bookmarks/sdts/core/app/custom/rawParts`. Defaults to fixtures sweep.
- `docx_write_example.nim` — builder: `newDocx/newParagraph/addText/addRun/newRun/newTable/cell/addTable/writeDocx`.
- `docx_perf.nim` — perf harness: `readDocx` benches + synthetic 20k-para doc via `newZipWriter`.
- `xlsx_read_example.nim` — `openXlsx/getSheetList/getRows/closeXlsx`, walks `tests/fixtures/xlsx/`.
- `example_pdf.nim`, `example_pdf_simple.nim`, `example_pdf_write.nim`, `example_pdf_report.nim` — high/low-level write, embedded fonts, CJK.
- `example_pdf_search.nim` — `extractDocumentText/searchText` + `openparser/fuzzy` caller-side.
- `example_pdf_sheet.nim` — `extractSheet` rows + tables.
- `example_pdf_forms.nim` — fill/flatten.
- `example_pdf_merge.nim` — merge/extract.
- `example_pdf_attach.nim` — embed/extract.
- `example_pdf_sign.nim` — list/verify/placeholder.
- `config.nims`, `hello.pdf` — example config + output.

Run with `clue build examples/<file>.nim` (do not run while another agent holds the tree; docs only).
