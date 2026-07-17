#!/bin/bash
set -e
clang++ -std=c++11 -arch arm64 -DUNIX -DSIZEOF_VOID_P=8 \
  -I/opt/cprocsp/include -I/opt/cprocsp/include/cpcsp \
  "$1.cpp" \
  -L/opt/cprocsp/lib -F/Library/Frameworks -framework CPROCSP -lcapi10 -lrdrsup -flat_namespace \
  -o "$1"
