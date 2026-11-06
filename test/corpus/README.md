# Real-file PNG corpus

Seven real-world PNGs, all verified byte-exact against ImageMagick.
Committed as binaries: they are the only oracle in the tree this decoder did not
produce, and CI must grade them rather than skip. `tools/fetch_corpus.sh`
re-downloads them if they are ever lost; the expected hashes are the authority,
not the download.

Expected RGBA8 output hashes are in `expected.txt`.

| file | geometry | colour type |
| :--- | :--- | :--- |
| apng-10f.png | 128x128 | palette, 10-frame APNG |
| big-4k.png | 3840x2160 | greyscale + alpha |
| gray-512.png | 512x512 | greyscale |
| lorem-1920x1080.png | 1920x1080 | palette |
| lorem-1mb.png | 1024x325 | truecolour |
| transparent-256.png | 256x256 | truecolour + alpha |
| wikimedia-800.png | 3120x3920 | truecolour, 12MP |
