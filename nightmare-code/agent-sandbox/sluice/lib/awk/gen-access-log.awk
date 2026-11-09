BEGIN {
    srand(seed)
    np = split("/ /index.html /api/v1/orders /api/v1/orders/1042 /api/v1/users/me /api/v1/search?q=bash /static/app.js /static/app.css /favicon.ico /healthz /login /admin /wp-login.php /.env", paths, " ")
    split("120 20 160 60 70 40 140 90 30 200 25 6 8 3", weights, " ")
    total_weight = 0
    for (i = 1; i <= np; i++) {
        total_weight += weights[i]
        cumulative[i] = total_weight
    }
    nua = split("Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0|Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 Safari/605.1.15|curl/8.9.1|Googlebot/2.1 (+http://www.google.com/bot.html)", agents, "|")
    for (i = 1; i <= 48; i++) clients[i] = sprintf("203.0.113.%d", i * 5)
    scraper = "198.51.100.77"
    outage_from = 13 * 60 + 40
    outage_to = outage_from + 90

    for (i = 0; i < n; i++) {
        t = int(i * 86400 / n)
        minute = int(t / 60)

        r = rand() * total_weight
        for (p = 1; p < np && r >= cumulative[p]; p++) ;
        path = paths[p]

        ip = (rand() < 0.33) ? scraper : clients[int(rand() * 48) + 1]
        agent = (ip == scraper) ? "python-requests/2.32.3" : agents[int(rand() * nua) + 1]
        if (path == "/healthz") agent = "kube-probe/1.31"
        method = (path == "/login" || (path == "/api/v1/orders" && rand() < 0.3)) ? "POST" : "GET"

        status = 200
        if (path == "/admin") status = 403
        else if (path == "/wp-login.php" || path == "/.env") status = 404
        else if (path == "/login" && method == "POST") status = (rand() < 0.8) ? 302 : 401
        else if (path ~ /^\/static\// && rand() < 0.4) status = 304
        else if (rand() < 0.01) status = 404

        if (incident && minute >= outage_from && minute < outage_to && path !~ /^\/static\// && rand() < 0.6)
            status = (rand() < 0.7) ? 502 : 503
        else if (rand() < 0.003)
            status = 500

        ms = 2 - log(1 - rand()) * 35
        if (path ~ /search/) ms *= 6
        if (path == "/healthz") ms = 1 + rand() * 2
        if (status >= 500) ms = 1000 + rand() * 4000

        bytes = (status == 200) ? int(400 + rand() * 24000) : (status == 304 ? 0 : int(150 + rand() * 300))
        printf "%s - - [%s:%02d:%02d:%02d +0000] \"%s %s HTTP/1.1\" %d %d \"-\" \"%s\" %.3f\n", ip, day, int(t / 3600), int(t % 3600 / 60), t % 60, method, path, status, bytes, agent, ms / 1000
    }
    if (incident) print "203.0.113.5 - - [" day ":23:59:59 +0000] \"GET /api/v1/ord"
}
