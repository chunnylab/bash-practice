#!/bin/bash

shopt -s nullglob
files=(testfile_[0-9]*.sh)

if (( ${#files[@]} == 0 )); then
    echo "no files to run"
    exit 0
else
    echo "found ${#files[@]} file(s)"
fi

for f in "${files[@]}"; do
    "./$f" || echo "run files fail... please check runfiles.sh"
done