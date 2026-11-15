#!/bin/zsh
set -eu
COMPANION_DIR="${0:A:h}"
exec /usr/bin/env python3 "$COMPANION_DIR/companion.py" start
