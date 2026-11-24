## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Spreadsheet `.xlsx`/`.xlsm`/`.xltx`/`.xltm`/`.xlam` (OOXML
## SpreadsheetML) reader and writer.
##
## Lazy like excelize: `openXlsx` maps the workbook and sheet parts;
## sheets and shared strings parse on first getter access. Phase A
## exposes raw values + types; number formatting lands in Phase B.
## The writer (`newXlsxDoc` + `setCell*` + `saveXlsx`) owns a separate
## builder model (DOCX-style); see `xlsx/write`.

import std/[strutils, tables, os, tempfiles, times, memfiles, math, algorithm]
import buffalo
import openparser/colors
import openparser/xml
import opendocs/zip

# Implementation split: model, shared helpers, cell refs, stylesheet,
# number/date formatting, workbook, shared strings, sheets, rich text,
# docProps, and the open flow live in `xlsx/` but are included here, so
# module `xlsx` keeps one canonical home for every symbol. Order matters:
# helpers before part readers, open flow before writer emit + builder
# (open-edit hydrates through the reader API), writer last.
include xlsx/types
include xlsx/base
include xlsx/cell
include xlsx/styles
include xlsx/numfmttok
include xlsx/locale_data
include xlsx/locale
include xlsx/numfmt
include xlsx/formulatok
include xlsx/workbook
include xlsx/sharedstrings
include xlsx/sheet
include xlsx/richtext
include xlsx/docprops
include xlsx/reader
include xlsx/emit
include xlsx/write
