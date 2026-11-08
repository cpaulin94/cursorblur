#!/bin/bash
# Compila e (opzionalmente) avvia cursorblur
set -e
cd "$(dirname "$0")"
swiftc -O cursorblur.swift -o cursorblur
echo "Build ok → ./cursorblur"
if [ "$1" = "run" ]; then
  pkill -x cursorblur 2>/dev/null || true
  ./cursorblur "${@:2}"
fi
