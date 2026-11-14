#!/usr/bin/env sh
# Rebuild erd.svg and erd.png from erd.dot (needs Graphviz: https://graphviz.org/download/).
# Run from anywhere: sh docs/build_erd.sh
cd "$(dirname "$0")" || exit 1
dot -Tsvg erd.dot -o erd.svg && dot -Tpng -Gdpi=150 erd.dot -o erd.png && echo "Built erd.svg and erd.png"
