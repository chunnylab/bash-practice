#!/bin/bash

DIR="$(cd "$(dirname "$0")" && pwd)"

if (( $# >= 1 )); then
    count=$1
else
    read -r -p "how many files do you want" count
fi

if (( $# >= 2 )); then
    delay=$2
else read -r -p "how many pipeline delay per process do you want" delay
fi

if ! [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "delay must be a number" >&2
    exit 1
fi

echo "== step 1: create"
bash "$DIR/createfile.sh" "$count" || { echo "create step failed" >&2; exit 1; }

echo "waiting $delay second(s) ..."
sleep "$delay"

echo "== step 2 runfile(s)"
bash "$DIR/runfiles.sh"

echo "waiting $delay second(s) ..."
sleep "$delay"

echo "== step 3 remove file(s)"
bash "$DIR/rmfiles.sh"

echo "done"
