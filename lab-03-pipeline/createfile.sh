#!/bin/bash

echo "lab 02 create files with detail"

MAX_LIMIT=20

if (( $# >= 1 )); then
    filecount=$1
else
    read -r -p "how many bash file do you want : " filecount
fi

if ! [[ "$filecount" =~ ^[0-9]+$ ]] || [ "$filecount" -le 0 ]; then
    echo "number must be 1-$MAX_LIMIT"
    exit 1
elif (( 10#$filecount > MAX_LIMIT )); then
    echo "number must be 1-$MAX_LIMIT"
    exit 1
else
    created=0
    for (( i = 1; i <= 10#$filecount; i++ )); do
        if cat > "testfile_$i.sh" <<EOF
#!/bin/bash
echo "testfile_$i.sh say : I am file $i"
EOF
    then
        chmod +x "testfile_$i.sh"
        (( created++ ))
    else
        echo "create testfile_$i.sh fail..." >&2
    fi
    done
    echo "create $created file(s)"
    if (( created != 10#$filecount )); then
    exit 1
    fi
fi

