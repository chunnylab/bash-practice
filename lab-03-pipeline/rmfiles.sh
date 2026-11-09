#!/bin/bash

shopt -s  nullglob 
files=(testfile_[0-9]*.sh)

if (( ${#files[@]} == 0 )); then
    echo "no testfile to remove"
    exit 0
fi

echo "found ${#files[@]} file(s)"

for f in "${files[@]}"; do
    rm -- "$f" || echo "remove $f fail..."
done

