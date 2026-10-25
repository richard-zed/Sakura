#!/bin/sh
# BusyBox wget here has no -4; IPv6 hangs. Download sequentially.
set -e
cd "$(dirname "$0")/../test/corpus"
wget -q -T 30 -O apng-10f.png          "https://loremfile.dev/png/animated-apng-10frames-128x128.png"
wget -q -T 30 -O gray-512.png          "https://loremfile.dev/png/grayscale-512x512.png"
wget -q -T 30 -O lorem-1920x1080.png   "https://loremfile.dev/png/1920x1080.png"
wget -q -T 30 -O lorem-1mb.png         "https://loremfile.dev/png/1mb.png"
wget -q -T 30 -O transparent-256.png   "https://loremfile.dev/png/transparent-256x256.png"
wget -q -T 30 -O wikimedia-800.png     "https://upload.wikimedia.org/wikipedia/commons/6/6a/PNG_Test.png"
echo "note: big-4k.png is not downloadable; supply separately." >&2
