#!/bin/bash

DIR="$(cd "$(dirname "$0")" && pwd)"

if (( $# >= 1 )); then
    count=$1
else
    read -r -p "how many log line you want(1 - 1000) : " count
fi

if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "input must be a number" >&2
    exit 1
fi

count=$(( 10#$count ))

if (( count < 1 || count > 1000 )); then
    echo "count must be between 1 and 1000" >&2
    exit 1
fi

    #ip
    ips=()
    for (( n = 0; n < 8; n++ )); do
        ip1=$(( RANDOM % 256 )) #target max 255 but startcount from 0, then have to put 256 to max 255
        ip2=$(( RANDOM % 256 ))
        ip3=$(( RANDOM % 256 ))
        ip4=$(( RANDOM % 256 ))
        ips+=("$ip1.$ip2.$ip3.$ip4")
    done
        #METHOD
    methods=(GET POST PUT DELETE)

    #URL
    url=(/ /login /api /user /admin /console)

    #STATUS
    status=(200 200 200 200 200 404 404 500)

    #DATE
    date="$(date '+%d/%b/%Y:%H:%M:%S %z')"
if [ $count -le 1000 ]; then
    i=1
    while (( i <= count )); do
        #IP
        random_ip="${ips[RANDOM % ${#ips[@]}]}"

        #METHOD
        random_methods="${methods[RANDOM % ${#methods[@]}]}"

        #URL
        random_url="${url[RANDOM % ${#url[@]}]}"

        #STATUS
        random_status="${status[RANDOM % ${#status[@]}]}"

        #BYTES
        bytes=$(( RANDOM % 32767 ))

        printf '%s - - [%s] "%s %s HTTP/1.1" %s %s\n' "$random_ip" "$date" "$random_methods" "$random_url" "$random_status" "$bytes"
        (( i++ ))
    done > "$DIR/access.log"
else
    echo "count must be less or equal 1000, Please check the value"
    exit 1
fi