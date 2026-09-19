## Spreadsheet `.xlsx`/`.xlsm`/`.xltx`/`.xltm`/`.xlam` (OOXML
## SpreadsheetML) reader.
##
## Lazy like excelize: `openXlsx` maps the workbook and sheet parts;
## sheets and shared strings parse on first getter access. Phase A
## exposes raw values + types; number formatting lands in Phase B.

import std/[strutils, tables, os, tempfiles]
import openparser/xml
import opendocs/zip

# Implementation split: model, shared helpers, cell refs, stylesheet,
# number/date formatting, workbook, shared strings, sheets, and the open
# flow live in `xlsx/` but are included here, so module `xlsx` keeps one
# canonical home for every symbol. Order matters: helpers before part
# readers, open flow last.
include xlsx/types
include xlsx/base
include xlsx/cell
include xlsx/styles
include xlsx/numfmt
include xlsx/workbook
include xlsx/sharedstrings
include xlsx/sheet
include xlsx/reader
