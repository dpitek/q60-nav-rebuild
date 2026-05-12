/*
 * valhalla-httpd.c — Minimal HTTP proxy for valhalla_service (CLI mode)
 *
 * Listens on TCP port 8002, accepts HTTP POST requests, maps the path to
 * a Valhalla action, executes valhalla_service in single-shot mode, and
 * returns the JSON response.
 *
 * Build:
 *   gcc -m32 -march=i686 -mtune=bonnell -O2 -o valhalla-httpd valhalla-httpd.c
 *
 * Usage:
 *   ./valhalla-httpd /opt/valhalla/valhalla.json [port]
 *
 * Endpoints mirrored from Valhalla HTTP API:
 *   POST /route            → route
 *   POST /locate           → locate
 *   POST /sources_to_targets → sources_to_targets
 *   POST /isochrone        → isochrone
 *   POST /trace_route      → trace_route
 *   POST /trace_attributes → trace_attributes
 *   GET  /status           → status
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <signal.h>

#define DEFAULT_PORT     8002
#define MAX_REQUEST      (4 * 1024 * 1024)  /* 4MB max request */
#define MAX_RESPONSE     (8 * 1024 * 1024)  /* 8MB max response */
#define VALHALLA_BIN     "/opt/valhalla/bin/valhalla_service"
#define BACKLOG          8

static char g_config[512];

/* Map HTTP path to Valhalla action string */
static const char *path_to_action(const char *path) {
    if (strncmp(path, "/route",             6)  == 0) return "route";
    if (strncmp(path, "/locate",            7)  == 0) return "locate";
    if (strncmp(path, "/sources_to_targets",20) == 0) return "sources_to_targets";
    if (strncmp(path, "/optimized_route",   16) == 0) return "optimized_route";
    if (strncmp(path, "/isochrone",         10) == 0) return "isochrone";
    if (strncmp(path, "/trace_route",       12) == 0) return "trace_route";
    if (strncmp(path, "/trace_attributes",  17) == 0) return "trace_attributes";
    if (strncmp(path, "/height",             7) == 0) return "height";
    if (strncmp(path, "/status",             7) == 0) return "status";
    if (strncmp(path, "/expansion",         10) == 0) return "expansion";
    return NULL;
}

/* Call valhalla_service, capture stdout into *out (caller must free) */
static int run_valhalla(const char *action, const char *body, char **out) {
    int pipefd[2];
    if (pipe(pipefd) < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }

    if (pid == 0) {
        /* Child: redirect stdout to pipe */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        /* Redirect stderr to /dev/null */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        execl(VALHALLA_BIN, "valhalla_service",
              g_config, action, body, NULL);
        _exit(127);
    }

    /* Parent: read from pipe */
    close(pipefd[1]);

    char  *buf  = malloc(MAX_RESPONSE);
    size_t used = 0;
    ssize_t n;
    if (!buf) { close(pipefd[0]); waitpid(pid, NULL, 0); return -1; }

    while ((n = read(pipefd[0], buf + used, MAX_RESPONSE - used - 1)) > 0)
        used += n;
    buf[used] = '\0';
    close(pipefd[0]);

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && used > 0) {
        *out = buf;
        return (int)used;
    }
    free(buf);
    return -1;
}

/* Parse first line of HTTP request into method and path */
static int parse_request_line(const char *req, char *method, char *path) {
    const char *p = req;
    int i = 0;
    while (*p && *p != ' ' && i < 7) method[i++] = *p++;
    method[i] = '\0';
    if (*p == ' ') p++;
    i = 0;
    while (*p && *p != ' ' && *p != '\r' && *p != '\n' && i < 127)
        path[i++] = *p++;
    path[i] = '\0';
    return (i > 0) ? 0 : -1;
}

/* Extract Content-Length header value */
static int get_content_length(const char *req) {
    const char *p = strcasestr(req, "content-length:");
    if (!p) return 0;
    p += 15;
    while (*p == ' ') p++;
    return atoi(p);
}

/* Find end of HTTP headers (\r\n\r\n) and return pointer to body */
static const char *find_body(const char *req, size_t len) {
    for (size_t i = 0; i + 3 < len; i++) {
        if (req[i]=='\r' && req[i+1]=='\n' && req[i+2]=='\r' && req[i+3]=='\n')
            return req + i + 4;
    }
    return NULL;
}

/* Send an HTTP response */
static void send_response(int fd, int code, const char *ctype,
                           const char *body, size_t body_len) {
    char hdr[256];
    const char *reason = (code == 200) ? "OK" :
                         (code == 400) ? "Bad Request" :
                         (code == 404) ? "Not Found" :
                         (code == 500) ? "Internal Server Error" : "Error";
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        code, reason, ctype, body_len);
    write(fd, hdr, hlen);
    if (body && body_len > 0)
        write(fd, body, body_len);
}

static void handle_client(int cfd) {
    char  *req = malloc(MAX_REQUEST);
    if (!req) { close(cfd); return; }

    /* Read full request */
    size_t  total = 0;
    ssize_t n;
    while (total < MAX_REQUEST - 1) {
        n = read(cfd, req + total, MAX_REQUEST - 1 - total);
        if (n <= 0) break;
        total += n;
        /* Check if we have headers yet */
        req[total] = '\0';
        const char *body = find_body(req, total);
        if (body) {
            int clen = get_content_length(req);
            size_t header_len = (size_t)(body - req);
            size_t body_have  = total - header_len;
            if (clen <= 0 || body_have >= (size_t)clen) break;
        }
    }
    req[total] = '\0';

    char method[8], path[128];
    if (parse_request_line(req, method, path) < 0) {
        send_response(cfd, 400, "application/json",
                      "{\"error\":\"bad request\"}", 22);
        free(req); close(cfd); return;
    }

    /* Handle GET /status */
    if (strcmp(method, "GET") == 0 && strcmp(path, "/status") == 0) {
        const char *ok = "{\"version\":\"3.4.0\",\"status\":\"running\"}";
        send_response(cfd, 200, "application/json", ok, strlen(ok));
        free(req); close(cfd); return;
    }

    const char *action = path_to_action(path);
    if (!action) {
        send_response(cfd, 404, "application/json",
                      "{\"error\":\"unknown endpoint\"}", 27);
        free(req); close(cfd); return;
    }

    /* Extract JSON body */
    const char *body_ptr = find_body(req, total);
    const char *body_json = (body_ptr && *body_ptr) ? body_ptr : "{}";

    char *result = NULL;
    int   rlen   = run_valhalla(action, body_json, &result);
    if (rlen < 0) {
        send_response(cfd, 500, "application/json",
                      "{\"error\":\"valhalla_service failed\"}", 34);
    } else {
        send_response(cfd, 200, "application/json", result, (size_t)rlen);
        free(result);
    }

    free(req);
    close(cfd);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <valhalla.json> [port]\n", argv[0]);
        return 1;
    }
    strncpy(g_config, argv[1], sizeof(g_config) - 1);
    int port = (argc >= 3) ? atoi(argv[2]) : DEFAULT_PORT;

    /* Ignore SIGPIPE from closed sockets */
    signal(SIGPIPE, SIG_IGN);
    /* Reap children automatically */
    signal(SIGCHLD, SIG_DFL);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return 1; }

    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(lfd, BACKLOG) < 0) { perror("listen"); return 1; }

    fprintf(stderr, "[valhalla-httpd] Listening on port %d (config: %s)\n",
            port, g_config);
    fflush(stderr);

    for (;;) {
        struct sockaddr_in caddr;
        socklen_t clen = sizeof(caddr);
        int cfd = accept(lfd, (struct sockaddr *)&caddr, &clen);
        if (cfd < 0) { if (errno == EINTR) continue; perror("accept"); break; }

        pid_t pid = fork();
        if (pid == 0) {
            close(lfd);
            handle_client(cfd);
            _exit(0);
        }
        close(cfd);
        /* Reap any zombies */
        while (waitpid(-1, NULL, WNOHANG) > 0) {}
    }
    return 0;
}
