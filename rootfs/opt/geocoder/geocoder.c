/*
 * geocoder-server.c — Offline geocoding HTTP server for q60nav
 *
 * Single-file C99. No external deps except SQLite3 + POSIX.
 * Compiled for i386 (Intel Atom E6xx/Bonnell, 32-bit Linux).
 *
 * Usage:
 *   geocoder-server --db /path/to/places.db --port 4000
 *
 * Endpoints (Pelias-compatible GeoJSON):
 *   GET /search?text=QUERY&size=N
 *   GET /reverse?point.lat=LAT&point.lon=LON&size=N
 *   GET /status   → {"status":"OK"}
 *   GET /api?q=QUERY&limit=N   → alias for /search (legacy compat)
 *   GET /reverse?lat=LAT&lon=LON&limit=N → alias for /reverse (legacy)
 *
 * Response schema (Pelias GeoJSON — matches SearchService.cpp):
 *   {
 *     "features": [
 *       {
 *         "type": "Feature",
 *         "geometry": {"type":"Point","coordinates":[lon,lat]},
 *         "properties": {
 *           "name": "...",
 *           "label": "name, city, state",
 *           "locality": "city",
 *           "region_a": "NC",
 *           "country": "us"
 *         }
 *       }
 *     ]
 *   }
 *
 * Build (inside q60-toolchain Docker):
 *   gcc -m32 -march=i686 -mtune=bonnell -O2 -o geocoder-server geocoder.c \
 *       -lsqlite3 -lpthread -Wall
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   /* strcasecmp */
#include <stdint.h>
#include <signal.h>
#include <errno.h>
#include <ctype.h>

#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <sqlite3.h>

/* ── Constants ────────────────────────────────────────────────────────────── */

#define BUF_SIZE        (64 * 1024)   /* 64KB request buffer                 */
#define RESP_INIT_SIZE  (256 * 1024)  /* 256KB initial response buffer        */
#define DEFAULT_PORT    4000
#define DEFAULT_LIMIT   8
#define MAX_LIMIT       25
#define BBOX_DELTA      0.05          /* ~5.5km bounding box half-width       */

/* ── Globals ──────────────────────────────────────────────────────────────── */

static sqlite3 *g_db   = NULL;
static int      g_port = DEFAULT_PORT;

/* ── Signal handler ───────────────────────────────────────────────────────── */

static void handle_sigterm(int sig)
{
    (void)sig;
    fprintf(stderr, "[geocoder] SIGTERM received — closing DB and exiting\n");
    if (g_db) {
        sqlite3_close(g_db);
        g_db = NULL;
    }
    exit(0);
}

/* ── URL decoder ──────────────────────────────────────────────────────────── */

static void url_decode(const char *src, char *dst, size_t dst_len)
{
    size_t i = 0;
    size_t j = 0;
    while (src[i] && j + 1 < dst_len) {
        if (src[i] == '%' && isxdigit((unsigned char)src[i+1])
                          && isxdigit((unsigned char)src[i+2])) {
            char hex[3] = { src[i+1], src[i+2], '\0' };
            dst[j++] = (char)strtol(hex, NULL, 16);
            i += 3;
        } else if (src[i] == '+') {
            dst[j++] = ' ';
            i++;
        } else {
            dst[j++] = src[i++];
        }
    }
    dst[j] = '\0';
}

/* ── Query-string parser ──────────────────────────────────────────────────── */

/*
 * Extract value for `key` from a query string like "text=foo&size=5".
 * Returns 1 on success, 0 if not found.
 * Output is URL-decoded into `val` (max val_len bytes including NUL).
 */
static int qs_get(const char *qs, const char *key, char *val, size_t val_len)
{
    size_t klen = strlen(key);
    const char *p = qs;
    while (p && *p) {
        /* skip leading '?' or '&' */
        while (*p == '?' || *p == '&') p++;
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *start = p + klen + 1;
            const char *end   = start;
            while (*end && *end != '&') end++;
            size_t raw_len = (size_t)(end - start);
            char *raw = (char *)malloc(raw_len + 1);
            if (!raw) return 0;
            memcpy(raw, start, raw_len);
            raw[raw_len] = '\0';
            url_decode(raw, val, val_len);
            free(raw);
            return 1;
        }
        /* advance past this parameter */
        p = strchr(p, '&');
        if (p) p++;
    }
    return 0;
}

/* ── Response buffer ──────────────────────────────────────────────────────── */

typedef struct {
    char   *data;
    size_t  len;
    size_t  cap;
} Buf;

static int buf_init(Buf *b, size_t cap)
{
    b->data = (char *)malloc(cap);
    if (!b->data) return 0;
    b->len  = 0;
    b->cap  = cap;
    return 1;
}

static int buf_append(Buf *b, const char *s, size_t n)
{
    while (b->len + n + 1 > b->cap) {
        size_t new_cap = b->cap * 2;
        char *p = (char *)realloc(b->data, new_cap);
        if (!p) return 0;
        b->data = p;
        b->cap  = new_cap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 1;
}

static int buf_appends(Buf *b, const char *s)
{
    return buf_append(b, s, strlen(s));
}

/* ── JSON string escaper ──────────────────────────────────────────────────── */

static void json_escape(const char *src, char *dst, size_t dst_len)
{
    size_t j = 0;
    for (size_t i = 0; src[i] && j + 6 < dst_len; i++) {
        unsigned char c = (unsigned char)src[i];
        switch (c) {
            case '"':  dst[j++] = '\\'; dst[j++] = '"';  break;
            case '\\': dst[j++] = '\\'; dst[j++] = '\\'; break;
            case '\n': dst[j++] = '\\'; dst[j++] = 'n';  break;
            case '\r': dst[j++] = '\\'; dst[j++] = 'r';  break;
            case '\t': dst[j++] = '\\'; dst[j++] = 't';  break;
            default:
                if (c < 0x20) {
                    /* control chars → \uXXXX */
                    j += (size_t)snprintf(dst+j, dst_len-j, "\\u%04x", c);
                } else {
                    dst[j++] = (char)c;
                }
                break;
        }
    }
    dst[j] = '\0';
}

/* ── State abbreviation table (US) ───────────────────────────────────────── */

/*
 * Pelias uses `region_a` for 2-letter state abbreviation.
 * SearchService.cpp reads props["region_a"].toString() for display.
 * We store full state name in DB; derive abbreviation at response time.
 */
static const char *state_abbrev(const char *state)
{
    static const char *tbl[][2] = {
        {"North Carolina","NC"}, {"South Carolina","SC"}, {"Virginia","VA"},
        {"Georgia","GA"},        {"Tennessee","TN"},      {"Kentucky","KY"},
        {"West Virginia","WV"},  {"Maryland","MD"},       {"Delaware","DE"},
        {"Florida","FL"},        {"Alabama","AL"},        {"Mississippi","MS"},
        {"Arkansas","AR"},       {"Louisiana","LA"},      {"Texas","TX"},
        {"Oklahoma","OK"},       {"Kansas","KS"},         {"Missouri","MO"},
        {"Iowa","IA"},           {"Minnesota","MN"},      {"Wisconsin","WI"},
        {"Michigan","MI"},       {"Indiana","IN"},        {"Ohio","OH"},
        {"Pennsylvania","PA"},   {"New York","NY"},       {"Vermont","VT"},
        {"New Hampshire","NH"},  {"Maine","ME"},          {"Massachusetts","MA"},
        {"Rhode Island","RI"},   {"Connecticut","CT"},    {"New Jersey","NJ"},
        {"Illinois","IL"},       {"Nebraska","NE"},       {"South Dakota","SD"},
        {"North Dakota","ND"},   {"Montana","MT"},        {"Wyoming","WY"},
        {"Colorado","CO"},       {"New Mexico","NM"},     {"Arizona","AZ"},
        {"Utah","UT"},           {"Nevada","NV"},         {"Idaho","ID"},
        {"Oregon","OR"},         {"Washington","WA"},     {"California","CA"},
        {"Alaska","AK"},         {"Hawaii","HI"},
        {NULL, NULL}
    };
    if (!state || !state[0]) return "";
    for (int i = 0; tbl[i][0]; i++) {
        if (strcasecmp(state, tbl[i][0]) == 0) return tbl[i][1];
    }
    /* if already 2-char, return as-is */
    if (strlen(state) == 2) return state;
    return state;
}

/* ── Pelias feature builder ───────────────────────────────────────────────── */

/*
 * Append a single Pelias GeoJSON feature to `body`.
 * All string fields are JSON-escaped.
 * `first` controls leading comma.
 */
static void append_feature(Buf *body, int first,
                            const char *name, const char *city,
                            const char *state, const char *country,
                            double lat, double lon)
{
    char esc_name[512], esc_city[256], esc_label[1024];
    char lon_str[32], lat_str[32];
    const char *abbrev = state_abbrev(state);

    json_escape(name,  esc_name,  sizeof(esc_name));
    json_escape(city,  esc_city,  sizeof(esc_city));

    /* label = "name, city, ST" or subset if fields absent */
    if (esc_city[0] && abbrev[0])
        snprintf(esc_label, sizeof(esc_label), "%s, %s, %s",
                 esc_name, esc_city, abbrev);
    else if (esc_city[0])
        snprintf(esc_label, sizeof(esc_label), "%s, %s", esc_name, esc_city);
    else
        snprintf(esc_label, sizeof(esc_label), "%s", esc_name);

    snprintf(lon_str, sizeof(lon_str), "%.6f", lon);
    snprintf(lat_str, sizeof(lat_str), "%.6f", lat);

    if (!first) buf_appends(body, ",");
    buf_appends(body, "{\"type\":\"Feature\","
                       "\"geometry\":{\"type\":\"Point\","
                                     "\"coordinates\":[");
    buf_appends(body, lon_str);
    buf_appends(body, ",");
    buf_appends(body, lat_str);
    buf_appends(body, "]},"
                      "\"properties\":{"
                      "\"name\":\"");
    buf_appends(body, esc_name);
    buf_appends(body, "\",\"label\":\"");
    buf_appends(body, esc_label);
    buf_appends(body, "\",\"locality\":\"");
    buf_appends(body, esc_city);
    buf_appends(body, "\",\"region_a\":\"");
    buf_appends(body, abbrev);
    buf_appends(body, "\",\"country\":\"");
    buf_appends(body, country && country[0] ? country : "us");
    buf_appends(body, "\"}}");
}

/* ── HTTP response writer ─────────────────────────────────────────────────── */

static void send_response(int fd, int status, const char *status_text,
                           const Buf *body)
{
    char header[256];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.0 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, status_text, body->len);
    /* write() return ignored intentionally — connection-close response, client gone = fine */
    if (write(fd, header, (size_t)hlen) < 0) {}
    if (body->len > 0 && write(fd, body->data, body->len) < 0) {}
}

static void send_simple(int fd, int status, const char *status_text,
                         const char *json)
{
    Buf b;
    buf_init(&b, strlen(json) + 1);
    buf_appends(&b, json);
    send_response(fd, status, status_text, &b);
    free(b.data);
}

/* ── Forward geocode (/search or /api) ───────────────────────────────────── */

static void handle_search(int fd, const char *qs)
{
    char text_raw[512] = {0};
    char text[512]     = {0};
    char size_s[16]    = {0};
    int  limit         = DEFAULT_LIMIT;

    /* Support both ?text=... (Pelias) and ?q=... (legacy /api) */
    if (!qs_get(qs, "text", text_raw, sizeof(text_raw)))
        qs_get(qs, "q", text_raw, sizeof(text_raw));

    url_decode(text_raw, text, sizeof(text));

    if (qs_get(qs, "size", size_s, sizeof(size_s)))
        limit = atoi(size_s);
    else if (qs_get(qs, "limit", size_s, sizeof(size_s)))
        limit = atoi(size_s);

    if (limit < 1 || limit > MAX_LIMIT) limit = DEFAULT_LIMIT;

    if (!text[0]) {
        send_simple(fd, 200, "OK", "{\"features\":[]}");
        return;
    }

    fprintf(stderr, "[geocoder] search: \"%s\" limit=%d\n", text, limit);

    Buf body;
    if (!buf_init(&body, RESP_INIT_SIZE)) {
        send_simple(fd, 500, "Internal Server Error", "{\"error\":\"OOM\"}");
        return;
    }
    buf_appends(&body, "{\"features\":[");

    /* ── FTS5 query ──────────────────────────────────────────────────────── */
    const char *fts_sql =
        "SELECT p.name, p.city, p.state, p.country, p.lat, p.lon "
        "FROM places_fts fts "
        "JOIN places p ON fts.rowid = p.id "
        "WHERE places_fts MATCH ? "
        "ORDER BY rank "
        "LIMIT ?";

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(g_db, fts_sql, -1, &stmt, NULL);
    int count = 0;

    if (rc == SQLITE_OK) {
        /* FTS5 MATCH: quote the query to treat it as a phrase prefix search */
        char fts_query[600];
        /* Escape any double-quotes in text for FTS5 string literal */
        size_t qi = 0;
        fts_query[qi++] = '"';
        for (size_t ti = 0; text[ti] && qi + 3 < sizeof(fts_query); ti++) {
            if (text[ti] == '"') fts_query[qi++] = '"'; /* double the quote */
            fts_query[qi++] = text[ti];
        }
        fts_query[qi++] = '*'; /* prefix match */
        fts_query[qi++] = '"';
        fts_query[qi]   = '\0';

        sqlite3_bind_text(stmt, 1, fts_query, -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt,  2, limit);

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name    = (const char *)sqlite3_column_text(stmt, 0);
            const char *city    = (const char *)sqlite3_column_text(stmt, 1);
            const char *state   = (const char *)sqlite3_column_text(stmt, 2);
            const char *country = (const char *)sqlite3_column_text(stmt, 3);
            double      lat     = sqlite3_column_double(stmt, 4);
            double      lon     = sqlite3_column_double(stmt, 5);
            append_feature(&body, count == 0,
                           name    ? name    : "",
                           city    ? city    : "",
                           state   ? state   : "",
                           country ? country : "us",
                           lat, lon);
            count++;
        }
        sqlite3_finalize(stmt);
        stmt = NULL;
    } else {
        fprintf(stderr, "[geocoder] FTS prepare failed: %s\n",
                sqlite3_errmsg(g_db));
    }

    /* ── LIKE fallback if FTS returned nothing ───────────────────────────── */
    if (count == 0) {
        const char *like_sql =
            "SELECT name, city, state, country, lat, lon "
            "FROM places "
            "WHERE name LIKE ? "
            "LIMIT ?";
        rc = sqlite3_prepare_v2(g_db, like_sql, -1, &stmt, NULL);
        if (rc == SQLITE_OK) {
            char pattern[600];
            snprintf(pattern, sizeof(pattern), "%%%s%%", text);
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_STATIC);
            sqlite3_bind_int(stmt,  2, limit);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *name    = (const char *)sqlite3_column_text(stmt, 0);
                const char *city    = (const char *)sqlite3_column_text(stmt, 1);
                const char *state   = (const char *)sqlite3_column_text(stmt, 2);
                const char *country = (const char *)sqlite3_column_text(stmt, 3);
                double      lat     = sqlite3_column_double(stmt, 4);
                double      lon     = sqlite3_column_double(stmt, 5);
                append_feature(&body, count == 0,
                               name    ? name    : "",
                               city    ? city    : "",
                               state   ? state   : "",
                               country ? country : "us",
                               lat, lon);
                count++;
            }
            sqlite3_finalize(stmt);
        }
    }

    buf_appends(&body, "]}");
    send_response(fd, 200, "OK", &body);
    free(body.data);

    fprintf(stderr, "[geocoder] search \"%s\" → %d result(s)\n", text, count);
}

/* ── Reverse geocode (/reverse) ───────────────────────────────────────────── */

static void handle_reverse(int fd, const char *qs)
{
    char lat_s[32] = {0}, lon_s[32] = {0}, size_s[16] = {0};
    int  limit = 1;

    /* Support both ?point.lat= (Pelias) and ?lat= (legacy) */
    if (!qs_get(qs, "point.lat", lat_s, sizeof(lat_s)))
        qs_get(qs, "lat", lat_s, sizeof(lat_s));
    if (!qs_get(qs, "point.lon", lon_s, sizeof(lon_s)))
        qs_get(qs, "lon", lon_s, sizeof(lon_s));

    if (qs_get(qs, "size", size_s, sizeof(size_s)))
        limit = atoi(size_s);
    else if (qs_get(qs, "limit", size_s, sizeof(size_s)))
        limit = atoi(size_s);

    if (limit < 1 || limit > MAX_LIMIT) limit = 1;

    if (!lat_s[0] || !lon_s[0]) {
        send_simple(fd, 200, "OK", "{\"features\":[]}");
        return;
    }

    double lat = atof(lat_s);
    double lon = atof(lon_s);
    double min_lat = lat - BBOX_DELTA;
    double max_lat = lat + BBOX_DELTA;
    double min_lon = lon - BBOX_DELTA;
    double max_lon = lon + BBOX_DELTA;

    fprintf(stderr, "[geocoder] reverse: lat=%.6f lon=%.6f limit=%d\n",
            lat, lon, limit);

    /* R-tree bounding box → sort by squared distance */
    const char *sql =
        "SELECT p.name, p.city, p.state, p.country, p.lat, p.lon "
        "FROM places_rtree r "
        "JOIN places p ON r.id = p.id "
        "WHERE r.minlat >= ? AND r.maxlat <= ? "
        "  AND r.minlon >= ? AND r.maxlon <= ? "
        "ORDER BY ((p.lat - ?) * (p.lat - ?) + (p.lon - ?) * (p.lon - ?)) "
        "LIMIT ?";

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL);

    Buf body;
    if (!buf_init(&body, RESP_INIT_SIZE)) {
        send_simple(fd, 500, "Internal Server Error", "{\"error\":\"OOM\"}");
        return;
    }
    buf_appends(&body, "{\"features\":[");
    int count = 0;

    if (rc == SQLITE_OK) {
        sqlite3_bind_double(stmt, 1, min_lat);
        sqlite3_bind_double(stmt, 2, max_lat);
        sqlite3_bind_double(stmt, 3, min_lon);
        sqlite3_bind_double(stmt, 4, max_lon);
        sqlite3_bind_double(stmt, 5, lat);
        sqlite3_bind_double(stmt, 6, lat);
        sqlite3_bind_double(stmt, 7, lon);
        sqlite3_bind_double(stmt, 8, lon);
        sqlite3_bind_int(stmt,    9, limit);

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name    = (const char *)sqlite3_column_text(stmt, 0);
            const char *city    = (const char *)sqlite3_column_text(stmt, 1);
            const char *state   = (const char *)sqlite3_column_text(stmt, 2);
            const char *country = (const char *)sqlite3_column_text(stmt, 3);
            double      plat    = sqlite3_column_double(stmt, 4);
            double      plon    = sqlite3_column_double(stmt, 5);
            append_feature(&body, count == 0,
                           name    ? name    : "",
                           city    ? city    : "",
                           state   ? state   : "",
                           country ? country : "us",
                           plat, plon);
            count++;
        }
        sqlite3_finalize(stmt);
    } else {
        fprintf(stderr, "[geocoder] reverse prepare failed: %s\n",
                sqlite3_errmsg(g_db));
    }

    buf_appends(&body, "]}");
    send_response(fd, 200, "OK", &body);
    free(body.data);

    fprintf(stderr, "[geocoder] reverse lat=%.6f lon=%.6f → %d result(s)\n",
            lat, lon, count);
}

/* ── Request dispatcher ───────────────────────────────────────────────────── */

static void handle_connection(int fd)
{
    char   buf[BUF_SIZE];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';

    /* Parse: "GET /path?qs HTTP/1.x" */
    if (strncmp(buf, "GET ", 4) != 0) {
        send_simple(fd, 405, "Method Not Allowed", "{}");
        return;
    }

    char *path_start = buf + 4;
    char *sp = strchr(path_start, ' ');
    if (!sp) { send_simple(fd, 400, "Bad Request", "{}"); return; }
    *sp = '\0';

    /* Split path from query string */
    char *qs = strchr(path_start, '?');
    if (qs) { *qs = '\0'; qs++; } else { qs = ""; }

    char *path = path_start;

    if (strcmp(path, "/search") == 0 || strcmp(path, "/api") == 0) {
        handle_search(fd, qs);
    } else if (strcmp(path, "/reverse") == 0) {
        handle_reverse(fd, qs);
    } else if (strcmp(path, "/status") == 0) {
        send_simple(fd, 200, "OK", "{\"status\":\"OK\"}");
    } else {
        send_simple(fd, 404, "Not Found", "{}");
    }
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *db_path = NULL;
    int         port    = DEFAULT_PORT;

    /* Parse arguments */
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "--db")   == 0) db_path = argv[i+1];
        if (strcmp(argv[i], "--port") == 0) port    = atoi(argv[i+1]);
    }

    if (!db_path) {
        fprintf(stderr, "Usage: %s --db /path/to/places.db [--port 4000]\n",
                argv[0]);
        return 1;
    }

    g_port = port;

    /* Open SQLite DB (read-only is fine — we never write at runtime) */
    int rc = sqlite3_open_v2(db_path, &g_db,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                             NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "[geocoder] Cannot open DB %s: %s\n",
                db_path, sqlite3_errmsg(g_db));
        return 1;
    }

    /* Tune for read-heavy embedded workload */
    sqlite3_exec(g_db, "PRAGMA journal_mode=OFF",  NULL, NULL, NULL);
    sqlite3_exec(g_db, "PRAGMA synchronous=OFF",   NULL, NULL, NULL);
    sqlite3_exec(g_db, "PRAGMA cache_size=-16384", NULL, NULL, NULL); /* 16MB */
    sqlite3_exec(g_db, "PRAGMA temp_store=MEMORY", NULL, NULL, NULL);
    sqlite3_exec(g_db, "PRAGMA mmap_size=268435456", NULL, NULL, NULL); /* 256MB */

    fprintf(stderr, "[geocoder] DB opened: %s\n", db_path);

    /* Signals */
    signal(SIGTERM, handle_sigterm);
    signal(SIGPIPE, SIG_IGN);

    /* TCP socket */
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("[geocoder] socket"); return 1; }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); /* 127.0.0.1 only */

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[geocoder] bind");
        return 1;
    }
    if (listen(srv, 4) < 0) {
        perror("[geocoder] listen");
        return 1;
    }

    fprintf(stderr, "[geocoder] Listening on 127.0.0.1:%d\n", port);

    /* Main accept loop — single-threaded, sequential connections */
    while (1) {
        struct sockaddr_in cli;
        socklen_t cli_len = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &cli_len);
        if (fd < 0) {
            if (errno == EINTR) continue;
            perror("[geocoder] accept");
            break;
        }
        handle_connection(fd);
        close(fd);
    }

    close(srv);
    sqlite3_close(g_db);
    return 0;
}
