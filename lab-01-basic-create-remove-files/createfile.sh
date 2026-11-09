#!/bin/bash

echo "lab 01 create files"

MAX_LIMIT=20

if (( $# >= 1 )); then
    filecount=$1
else
    read -p "how many bash file do you want : " filecount
fi

if ! [[ "$filecount" =~ ^[0-9]+$ ]] || [ "$filecount" -le 0 ]; then
    echo "number must be 1-$MAX_LIMIT"
    exit 1
elif (( 10#$filecount > MAX_LIMIT )); then
    echo "number must be 1-$MAX_LIMIT"
    exit 1
else
    for (( i = 1; i <= 10#$filecount; i++ )); do
        touch testfile_$i.sh || echo "create file fail..."
    done
fi

echo "create $filecount file(s)"

