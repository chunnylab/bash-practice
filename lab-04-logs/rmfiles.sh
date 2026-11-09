#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"

shopt -s  nullglob 
files=("$DIR"/access*.log)

if (( ${#files[@]} == 0 )); then
    exit 0
fi

for f in "${files[@]}"; do
    rm -- "$f" || echo "remove $f fail..."
done

