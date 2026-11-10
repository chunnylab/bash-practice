#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "$DIR"

usage() {
    echo "usage: analyze.sh <logfile> [top_n]" >&2
}

report_top_ips() {
    local file=$1
    local top=$2
    awk '{ print $1 }' "$file" | sort | uniq -c | sort -rn | head -n "$top"
}

file=${1:-$DIR/access.log}
top=${2:-5}

report_status() {
    local file=$1
    awk '{ count[$9]++ }
         END {
             for (s in count)
                 printf "%s %d %.1f%%\n", s, count[s], count[s] / NR * 100
         }' "$file" | sort
}

usage
report_top_ips "$file" "$top"
report_status "$file"

