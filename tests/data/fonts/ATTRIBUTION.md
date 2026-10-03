# Font provenance

`DejaVuSans.ttf` and `LICENSE.dejavu.txt` are vendored from the sibling
harfbuzz checkout (`../harfbuzz/tests/data/`) so the writer-side font
suite runs hermetically. They were previously an undeclared sibling-path
dependency, which meant CI silently skipped 10 tests whenever that
checkout was absent.

Bitstream Vera Fonts Copyright, Copyright (c) 2003 Bitstream, Inc.
DejaVu changes are in the public domain. The licence permits
redistribution with the licence text. Full text in
`LICENSE.dejavu.txt`.

Size 739 KB is deliberate. The suite asserts that subsetting a large font
collapses it (`check full.len > 500_000`), which a purpose-built micro
font cannot demonstrate. `cjk-cff-micro.otf` and
`emoji-cbdt-micro.ttf` are the small-font counterpart and were built
separately; both are OFL 1.1 (see the header comments in
`tests/t_pdf_fontembed.nim` for their hb-subset invocations).

The tests also need the full font for scripts a micro font cannot carry:
Greek, Cyrillic, arrows, an emoji, the `fi` ligature, and the `AV` kern
pair. Plus a font that *lacks* CJK, so the missing-glyph failure path
(`cid missing glyph fails loudly`) can be exercised against DejaVu while
`cjk-cff-micro.otf` covers the present case.