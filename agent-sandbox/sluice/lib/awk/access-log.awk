BEGIN {
    FS = "\""
    if (top_n == "") top_n = 5
}

{
    if (NF < 7) { malformed++; next }

    if (split($1, head, " ") < 4 || substr(head[4], 1, 1) != "[") { malformed++; next }
    ip = head[1]
    minute = substr(head[4], 2, 17)

    split($3, sb, " ")
    status = sb[1] + 0
    if (status < 100 || status > 599) { malformed++; next }
    bytes = (sb[2] ~ /^[0-9]+$/) ? sb[2] + 0 : 0

    path = (split($2, req, " ") >= 2) ? req[2] : "-"
    sub(/\?.*/, "", path)

    total++
    class[int(status / 100)]++
    hits[path]++
    clients[ip]++
    per_minute[minute]++
    bytes_total += bytes
    if (status >= 500) errors_by_path[path]++

    rt = $7
    gsub(/[ \t\r]/, "", rt)
    if (rt ~ /^[0-9]+(\.[0-9]+)?$/) {
        ms = int(rt * 1000 + 0.5)
        latency[ms]++
        samples++
        sum_ms += ms
        if (ms > max_ms) max_ms = ms
    }
}

END {
    emit("requests", total + 0)
    emit("malformed_lines", malformed + 0)
    emit("bytes_total", bytes_total + 0)
    emit("status_2xx", class[2] + 0)
    emit("status_3xx", class[3] + 0)
    emit("status_4xx", class[4] + 0)
    emit("status_5xx", class[5] + 0)
    emit("unique_clients", count_keys(clients))

    if (total > 0) {
        emit("error_rate_5xx_bp", int(10000 * class[5] / total + 0.5))
        emit("error_rate_4xx_bp", int(10000 * class[4] / total + 0.5))
    }

    peak = 0
    peak_minute = "-"
    for (m in per_minute) {
        if (per_minute[m] > peak || (per_minute[m] == peak && m < peak_minute)) {
            peak = per_minute[m]
            peak_minute = m
        }
    }
    emit("peak_rpm", peak)
    emit("peak_minute", peak_minute)

    if (samples > 0) {
        split("50 90 95 99", pct, " ")
        for (i = 1; i <= 4; i++) {
            r = pct[i] * samples / 100
            rank[i] = (r == int(r)) ? r : int(r) + 1
        }
        cum = 0
        k = 1
        for (v = 0; v <= max_ms && k <= 4; v++) {
            if (!(v in latency)) continue
            cum += latency[v]
            while (k <= 4 && cum >= rank[k]) {
                emit("latency_p" pct[k] "_ms", v)
                k++
            }
        }
        emit("latency_samples", samples)
        emit("latency_avg_ms", int(sum_ms / samples + 0.5))
        emit("latency_max_ms", max_ms)
    }

    top("paths", hits)
    top("clients", clients)
    top("error_paths", errors_by_path)
}

function emit(name, value) {
    printf "metric\t%s\t%s\n", name, value
}

function count_keys(arr,    k, n) {
    n = 0
    for (k in arr) n++
    return n
}

function top(label, arr,    i, k, best, best_key, used) {
    for (i = 1; i <= top_n; i++) {
        best = -1
        best_key = ""
        for (k in arr) {
            if (k in used) continue
            if (arr[k] > best || (arr[k] == best && k < best_key)) {
                best = arr[k]
                best_key = k
            }
        }
        if (best < 0) break
        used[best_key] = 1
        printf "top\t%s\t%d\t%d\t%s\n", label, i, best, best_key
    }
}
