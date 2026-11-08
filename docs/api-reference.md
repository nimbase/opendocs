# API Reference

Canonical import homes:

- `import opendocs/docx` — `DocxDocument`, `readDocx/readDocxBytes`, `writeDocxBytes/writeDocx/buildPackage/writeDocumentXml/writeNumberingXml/writeStylesXml`, `parseInstr/serializeInstr`, `flatText/effectiveColor/getSections/getSection/getPageSettings/getHeaders/getFooters`, builder (`newDocx/newRun/newParagraph/addParagraph/addRun/addText/newTable/addTable/cell/newSection/addSection/nextRelId/addHeader/addFooter/addHyperlink/addImage/addFootnote/addComment/addNumbering/addStyle`), revisions (`acceptAllRevisions/rejectAllRevisions`), all types in `docx/types.nim`.
- `import opendocs/pdf` — `PdfDocument/readPdfBytes/openPdf/openPdfPassword/openPdfPasswordFile`, `PdfDoc/openDoc/openMappedDoc/close/cacheSize/resolve/catalog/pageCount/pageBoxes`, `extractText/pageImages`, `extractDocumentText/searchText/pageText`, `extractSheet/sheetPage`, `formFields/fieldNames/getField/isChecked/fillText/setCheck/selectRadio/selectChoice/selectChoices/resetFields/flattenFields`, `pageRefs/copyPage/extractPages/mergePdfs`, `embeddedFiles/embedFile/embedFileUpdate`, `docSignatures/verifyByteRangeHash/addSignaturePlaceholder`, `Pdf/newPdf/loadFont/setFont/fontNames/setPageSize/setMargin/setTitle/setAuthor/newPage/paragraph/heading/textAt/imageFromFile/build/save/close`, `ExportError/ImageFormat/ExportOptions/ExportPixels/encodeImage/saveImage/formatForPath/formatForExt`.
- `import opendocs/xlsx` — `XlsxFile/openXlsx/openXlsxBytes/closeXlsx`, `getSheetList/getSheetMap/getSheet/sheetPart/resolveSheetName`, `getRows/getCols/getCellValue/getCellType/getCellStyle/getCellStyleIdx/getCellFormula/formatApplied/cellDisplayValue/resolveRaw/formattedCellValue/formatInfo`, `getSheetDimension/getRowHeight/getRowVisible/getColWidth/getColVisible`, `getMergeCells/isMerged`, `getHyperlinks/getCellHyperlink`, `getDefinedNames`, `sharedStrings/sharedString`, `getCellRichText`, `cellTypeOf/columnNameToNumber/columnNumberToName/splitCellRef/joinCellName`, `loadStyles/numFmtIdFor/getStyle`, `parseNumFmt/renderNumFmt`, all `Xlsx*` types.
- `import opendocs/zip` — `ZipArchive/ZipEntry/ZipWriter/ZipMethod/ZipError`, `openZip/openZipBytes/filenames/findEntry/readEntry/readEntryByIndex/readEntryInto/extractEntryToFile`, `newZipWriter/addFile/toBytes/writeZip`, `deflateRaw/inflateRaw/inflateRawInto`.
- `import opendocs/exports` — `toExportPixels/encodeImage/saveImage/formatForExt/formatForPath`.

Low-level PDF (import explicitly):

- `opendocs/pdf/cos`, `pdf/lexer`, `pdf/source`, `pdf/xref`, `pdf/filters`, `pdf/content`, `pdf/gstate`, `pdf/cmap`, `pdf/cjkmaps`, `pdf/crypt`, `pdf/write`, `pdf/shape`, `pdf/fontembed`, `pdf/images`, `pdf/imgpipe`, `pdf/sfntcmap`, `pdf/docmodel`, `pdf/document`, `pdf/text`, `pdf/doctext`, `pdf/sheet`, `pdf/merge`, `pdf/forms`, `pdf/attach`, `pdf/sign`.

Errors:

- `DocxError` (CatchableError), `PdfError`, `XlsxError` (CatchableError), `ZipError` (IOError), `ExportError` (CatchableError).
