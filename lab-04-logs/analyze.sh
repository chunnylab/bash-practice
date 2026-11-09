#!/bin/bash

DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    # TODO: echo วิธีใช้ ไปที่ stderr   เช่น  usage: analyze.sh <logfile> [top_n]
    :
}

report_top_ips() {
    local file=$1
    local top=$2
    # TODO: pipeline ที่คุณเล่นใน terminal ไปแล้ว (ใช้ $top แทนเลข 5)
    :
}

report_status() {
    local file=$1
    # TODO: นับ status ($9) พร้อมเปอร์เซ็นต์ ด้วย awk
    :
}

report_error_urls() {
    local file=$1
    local top=$2
    # TODO: เลือกบรรทัดที่ status >= 400 แล้วนับ URL ($7)
    :
}

report_summary() {
    local file=$1
    # TODO: จำนวน request ทั้งหมด, bytes รวม, bytes เฉลี่ย (awk ตัวเดียว)
    :
}

main() {
    local file=$1
    local top=${2:-5}

    # TODO: ตรวจ argument  (ไม่มี $1 → usage + exit 1)
    # TODO: ตรวจไฟล์       (ไม่มีไฟล์ / ไฟล์ว่าง → error + exit 1)
    # TODO: ตรวจ top      (เป็นเลขบวกไหม)

    echo "== summary"
    report_summary "$file"

    echo "== top $top IPs"
    report_top_ips "$file" "$top"

    echo "== status codes"
    report_status "$file"

    echo "== top $top error URLs"
    report_error_urls "$file" "$top"
}

main "$@"
