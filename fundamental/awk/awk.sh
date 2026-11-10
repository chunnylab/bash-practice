#!/bin/bash
# awk fundamentals
# ข้อมูลฝึก: access.log จาก lab-04
#
# รูปแบบของ awk:   awk 'pattern { action }' file
#   pattern  = เงื่อนไข (ไม่ใส่ = ทุกบรรทัด)
#   action   = สิ่งที่ทำกับบรรทัดที่ผ่านเงื่อนไข (ไม่ใส่ = print ทั้งบรรทัด)
#
# 1 บรรทัดของ log แบ่งเป็น field ด้วยช่องว่าง:
#   219.206.123.161 - - [09/Nov/2026:23:43:14 +0700] "GET /api HTTP/1.1" 404 19472
#         $1        $2 $3          $4                   $5   $6   $7     $8   $9  $10
#   $1=IP  $5=method(มี " นำหน้า)  $7=URL  $9=status  $10=bytes

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/../../lab-04-logs/access.log"

show() { printf '\n--- %s\n' "$1"; }

# ---------------------------------------------------------------
# บท 1: field และ print
# ---------------------------------------------------------------
lesson_1() {
    show "1.1 print ทั้งบรรทัด (เหมือน cat) ตัดมา 2 บรรทัด"
    awk '{ print }' "$LOG" | head -n 2

    show "1.2 print เฉพาะ field: IP"
    awk '{ print $1 }' "$LOG" | head -n 3

    show "1.3 หลาย field คั่นด้วย , จะได้ช่องว่างคั่น"
    awk '{ print $1, $9 }' "$LOG" | head -n 3

    show "1.4 ใส่ข้อความเองปนได้ (ต้องอยู่ใน \"\")"
    awk '{ print "ip=" $1 " status=" $9 }' "$LOG" | head -n 3

    show "1.5 \$NF = field สุดท้าย  \$(NF-1) = ก่อนสุดท้าย"
    awk '{ print $NF, $(NF-1) }' "$LOG" | head -n 3

    # ลองเอง:
    # TODO 1.a  print เฉพาะ URL ($7) 3 บรรทัดแรก
    awk '{ print $7 }' "$LOG" | head -n 3
    # TODO 1.b  print "method url" คู่กัน (ระวัง $6 มีเครื่องหมาย " ติดมา)
}

# ---------------------------------------------------------------
# บท 2: ตัวแปรในตัว NR, NF
# ---------------------------------------------------------------
lesson_2() {
    show "2.1 NR = เลขบรรทัดปัจจุบัน"
    awk '{ print NR, $1 }' "$LOG" | head -n 3

    show "2.2 NF = จำนวน field ในบรรทัดนี้"
    awk '{ print NF }' "$LOG" | head -n 3

    show "2.3 เลือกบรรทัดด้วย NR (บรรทัด 2 ถึง 4)"
    awk 'NR >= 2 && NR <= 4' "$LOG"

    # ลองเอง:
    # TODO 2.a  print เฉพาะบรรทัดที่ 10
    # TODO 2.b  print เลขบรรทัดกับ bytes ($10) ของ 5 บรรทัดแรก
}

# ---------------------------------------------------------------
# บท 3: pattern (เงื่อนไข)
# ---------------------------------------------------------------
lesson_3() {
    show "3.1 เทียบตัวเลข: status เท่ากับ 404 (นับด้วย wc)"
    awk '$9 == 404' "$LOG" | wc -l

    show "3.2 มากกว่าหรือเท่ากับ: error ทั้งหมด (status >= 400)"
    awk '$9 >= 400' "$LOG" | wc -l

    show "3.3 เทียบข้อความ: method เป็น POST (มี \" ติดหน้า)"
    awk '$6 == "\"POST"' "$LOG" | head -n 2

    show "3.4 && (และ)  || (หรือ)  ! (ไม่)  ตัวอย่าง: status 500 และ URL /admin"
    awk '$9 == 500 && $7 == "/admin"' "$LOG" | head -n 2

    show "3.5 regex: ~ แปลว่า 'ตรงกับแบบ'  ใช้ /.../"
    awk '$7 ~ /^\/api/' "$LOG" | head -n 2

    # ลองเอง:
    # TODO 3.a  นับบรรทัดที่ status เป็น 200
    # TODO 3.b  print IP ของ request ที่ bytes มากกว่า 30000
    # TODO 3.c  print บรรทัดที่ URL เป็น /login และ status ไม่ใช่ 200
}

# ---------------------------------------------------------------
# บท 4: END และตัวแปรสะสม  (ตรงกับ report_summary ของ lab-04)
# ---------------------------------------------------------------
lesson_4() {
    show "4.1 ตัวแปรใน awk ไม่ต้องประกาศ เริ่มที่ 0 เอง"
    awk '{ sum += $10 } END { print sum }' "$LOG"

    show "4.2 END ทำครั้งเดียวหลังอ่านครบ ตอนนั้น NR = จำนวนบรรทัดทั้งหมด"
    awk 'END { print NR }' "$LOG"

    show "4.3 ค่าเฉลี่ย = ผลรวม / NR"
    awk '{ sum += $10 } END { print sum / NR }' "$LOG"

    show "4.4 หาค่ามากสุด: เทียบกับค่าที่จำไว้"
    awk '$10 > max { max = $10 } END { print max }' "$LOG"

    show "4.5 BEGIN ทำก่อนอ่านบรรทัดแรก (ใช้พิมพ์หัวตาราง)"
    awk 'BEGIN { print "total" } { sum += $10 } END { print sum }' "$LOG"

    # ลองเอง:
    # TODO 4.a  หาค่า bytes น้อยสุด (hint: ต้องตั้งค่าเริ่มต้นจากบรรทัดแรก NR == 1)
    # TODO 4.b  รวม bytes เฉพาะ request ที่ status เป็น 200
}

# ---------------------------------------------------------------
# บท 5: associative array  (ตรงกับ report_status ของ lab-04)
# ---------------------------------------------------------------
lesson_5() {
    show "5.1 array ใช้ข้อความเป็น key ได้: count[key]++ = นับจำนวนครั้ง"
    awk '{ count[$9]++ } END { for (s in count) print s, count[s] }' "$LOG" | sort

    show "5.2 นับ method"
    awk '{ count[$6]++ } END { for (m in count) print m, count[m] }' "$LOG" | sort

    show "5.3 รวมค่าตาม key: sum[key] += ค่า  (bytes รวมต่อ status)"
    awk '{ sum[$9] += $10 } END { for (s in sum) print s, sum[s] }' "$LOG" | sort

    show "5.4 key ผสมได้ ต่อข้อความด้วยช่องว่าง (status + method)"
    awk '{ count[$9 " " $6]++ } END { for (k in count) print k, count[k] }' "$LOG" | sort | head -n 4

    # ลองเอง:
    # TODO 5.a  นับจำนวน request ต่อ URL ($7)
    # TODO 5.b  นับจำนวน request ต่อ IP แล้วเรียงมากไปน้อยด้วย sort -rn
    # TODO 5.c  หาค่า bytes เฉลี่ยต่อ status
}

# ---------------------------------------------------------------
# บท 6: printf (จัดรูปผลลัพธ์)
# ---------------------------------------------------------------
lesson_6() {
    show "6.1 printf ไม่ขึ้นบรรทัดใหม่เอง ต้องใส่ \\n"
    awk 'NR <= 2 { printf "%s -> %s\n", $1, $9 }' "$LOG"

    show "6.2 ตัวแทนที่ใช้บ่อย: %s ข้อความ  %d จำนวนเต็ม  %.2f ทศนิยม 2 ตำแหน่ง"
    awk '{ sum += $10 } END { printf "avg=%.2f total=%d\n", sum / NR, sum }' "$LOG"

    show "6.3 เครื่องหมาย % จริงๆ ต้องเขียน %%  (สูตรเปอร์เซ็นต์ใน lab-04)"
    awk '{ c[$9]++ } END { for (s in c) printf "%s %d %.1f%%\n", s, c[s], c[s] / NR * 100 }' "$LOG" | sort

    show "6.4 กำหนดความกว้างคอลัมน์: %-6s ชิดซ้าย 6 ช่อง  %8d ชิดขวา 8 ช่อง"
    awk '{ c[$9]++ } END { for (s in c) printf "%-6s %8d\n", s, c[s] }' "$LOG" | sort

    # ลองเอง:
    # TODO 6.a  พิมพ์ "requests: N" โดย N คือจำนวนบรรทัดทั้งหมด
    # TODO 6.b  พิมพ์ตารางนับ method ให้ชื่อชิดซ้าย จำนวนชิดขวา
}

# ---------------------------------------------------------------
# บท 7: ใช้ awk กับ shell
# ---------------------------------------------------------------
lesson_7() {
    show "7.1 ตัวแปร shell ไม่เข้า single quote ต้องส่งด้วย -v"
    local limit=30000
    awk -v lim="$limit" '$10 > lim { n++ } END { print n+0 }' "$LOG"

    show "7.2 เปลี่ยนตัวคั่น field ด้วย -F (ตัวอย่างนี้ใช้ regex ตัดที่ ] [ / : และช่องว่าง)"
    awk -F'[][/: ]' 'NR <= 2 { print "วันที่", $5, $6, $7, "ชั่วโมง", $8 }' "$LOG"

    show "7.3 ส่งผลลัพธ์ awk เข้า pipeline ต่อได้ตามปกติ"
    awk '{ print $1 }' "$LOG" | sort | uniq -c | sort -rn | head -n 3

    show "7.4 รับค่าจากคำสั่งอื่นผ่าน pipe (ไม่ต้องใส่ชื่อไฟล์)"
    head -n 3 "$LOG" | awk '{ print $7 }'

    # ลองเอง:
    # TODO 7.a  รับ status จาก argument ของสคริปต์ ($1) แล้วนับบรรทัดที่ตรง
    # TODO 7.b  ทำ report_status ของ lab-04 ให้เสร็จ
}

# ---------------------------------------------------------------
# เลือกบทที่จะรัน:  ./awk.sh 3     หรือ  ./awk.sh all
# ---------------------------------------------------------------
case "${1:-all}" in
    1|2|3|4|5|6|7) "lesson_$1" ;;
    all) for n in 1 2 3 4 5 6 7; do "lesson_$n"; done ;;
    *) echo "usage: awk.sh [1-7|all]" >&2; exit 1 ;;
esac
