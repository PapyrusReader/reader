# Comic fixtures

These owned, generated pages use red, green and blue to verify decoded pixels
and natural filename ordering (`page1`, `page2`, `page10`). Regenerate PNG, CBZ,
and RAR4 files with `python3 test/support/generate_comic_fixtures.py`.

`pages-rar5.cbr` uses RAR 7.23, maximum compression and solid mode:

```
rar a -ep -m5 -s pages-rar5.cbr page10.png page2.png page1.png
```

The RAR binary is only a fixture-generation tool, not a runtime dependency.

`pages-rar4-compressed.cbr` uses RAR 6.24 with `-ma4 -ep -m5 -s`, exercising
compressed, solid RAR4 in addition to the generated stored archive.
