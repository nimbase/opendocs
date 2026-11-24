OLE fixtures: origin.

`vbaProject.bin` — the 16384-byte VBA project from the excelize
reference (`nimbase/references/excelize/test/vbaProject.bin`), copied
byte-identical (sha256
e24a20eb3419238b2ef8989fae057d0cce333ebb7186d426950c498b9540).
Real CFB with a red-black directory, MiniFAT-resident module streams
and 14 live entries. Consumed by `tests/t_ole.nim` (full inventory
pin) and `tests/t_xlsx_vba.nim` (integration). Every other OLE input
is synthesized in-code (`tests/ole_build.nim`).
