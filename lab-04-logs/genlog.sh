#!/bin/bash

DIR="$(cd "$(dirname "$0")" && pwd)"
count=1000
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

i=1
while (( i <= count )); do
    #IP
    random_ip="${ips[RANDOM % ${#ips[@]}]}"
    #echo "$ip1.$ip2.$ip3.$ip4" #for debug

    #METHOD
    random_methods="${methods[RANDOM % ${#methods[@]}]}"

    #URL
    random_url="${url[RANDOM % ${#url[@]}]}"

    #STATUS
    random_status="${status[RANDOM % ${#status[@]}]}"

    #BYTES
    bytes=$(( RANDOM % 32767 ))

    printf '%s - - [%s] "%s %s HTTP/1.1" %s %s\n' "$random_ip" "$(date '+%d/%b/%Y:%H:%M:%S %z')" "$random_methods" "$random_url" "$random_status" "$bytes"
    (( i++ ))
done > "$DIR/access.log"
