#!/bin/bash

echo "lab 01 create files"

MAX_LIMIT=20

read -p "how many bash file do you want : " filecount

if ! [[ "$filecount" =~ ^[0-9]+$ ]] || [ "$filecount" -le 0 ]; then