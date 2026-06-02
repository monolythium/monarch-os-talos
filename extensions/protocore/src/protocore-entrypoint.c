#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *env_or_default(const char *name, const char *fallback) {
    const char *value = getenv(name);
    return value && value[0] ? value : fallback;
}

static int is_truthy(const char *value) {
    return value && (strcmp(value, "true") == 0 || strcmp(value, "1") == 0 ||
                     strcmp(value, "yes") == 0 || strcmp(value, "on") == 0);
}

static int contains_case_insensitive(const char *haystack, const char *needle) {
    size_t needle_len = strlen(needle);

    if (needle_len == 0) {
        return 1;
    }

    for (const char *p = haystack; *p; ++p) {
        size_t i = 0;
        while (i < needle_len && p[i]) {
            char a = p[i];
            char b = needle[i];
            if (a >= 'A' && a <= 'Z') {
                a = (char)(a - 'A' + 'a');
            }
            if (b >= 'A' && b <= 'Z') {
                b = (char)(b - 'A' + 'a');
            }
            if (a != b) {
                break;
            }
            ++i;
        }
        if (i == needle_len) {
            return 1;
        }
    }

    return 0;
}

static int is_placeholder_value(const char *value) {
    return value &&
           (strchr(value, '<') || contains_case_insensitive(value, "replace-with") ||
            contains_case_insensitive(value, "changeme") ||
            contains_case_insensitive(value, "placeholder") ||
            contains_case_insensitive(value, "example-secret"));
}

static int validate_hex_digest(const char *value) {
    size_t len = strlen(value);

    if (len != 64) {
        return -1;
    }

    for (size_t i = 0; i < len; ++i) {
        char c = value[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
              (c >= 'A' && c <= 'F'))) {
            return -1;
        }
    }

    return 0;
}

static int require_readable_file(const char *path, const char *label) {
    if (!path || !path[0]) {
        fprintf(stderr, "%s path is required\n", label);
        return -1;
    }
    if (is_placeholder_value(path)) {
        fprintf(stderr, "%s path is still a placeholder\n", label);
        return -1;
    }
    if (access(path, R_OK) != 0) {
        fprintf(stderr, "%s is not readable: %s\n", label, path);
        return -1;
    }
    return 0;
}

static int reject_placeholder_env(const char *name) {
    const char *value = getenv(name);

    if (value && value[0] && is_placeholder_value(value)) {
        fprintf(stderr, "%s is still a placeholder; refusing to start\n", name);
        return -1;
    }
    return 0;
}

static int reject_inline_secret_envs(void) {
    const char *forbidden[] = {
        "PROTOCORE_KEYSTORE_PASSPHRASE",
        "PROTOCORE_OPERATOR_MNEMONIC",
        "PROTOCORE_OPERATOR_PRIVATE_KEY",
        "PROTOCORE_BLS_SHARE",
        "PROTOCORE_CLUSTER_KEY_SHARE",
        "PROTOCORE_KEY_SHARE",
        NULL,
    };

    for (const char **name = forbidden; *name; ++name) {
        const char *value = getenv(*name);
        if (value && value[0]) {
            fprintf(stderr, "%s is inline secret material; use the enrollment/secret file path instead\n", *name);
            return -1;
        }
    }

    return 0;
}

static int read_file_trimmed(const char *path, char *buf, size_t buf_len, const char *label) {
    if (require_readable_file(path, label) != 0) {
        return -1;
    }

    FILE *in = fopen(path, "rb");
    if (!in) {
        perror("fopen secret file");
        return -1;
    }

    size_t n = fread(buf, 1, buf_len - 1, in);
    if (ferror(in)) {
        perror("fread secret file");
        fclose(in);
        return -1;
    }
    if (!feof(in)) {
        fprintf(stderr, "%s is too large\n", label);
        fclose(in);
        return -1;
    }
    fclose(in);

    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
                     buf[n - 1] == ' ' || buf[n - 1] == '\t')) {
        buf[--n] = '\0';
    }

    if (is_placeholder_value(buf)) {
        fprintf(stderr, "%s contains placeholder content\n", label);
        return -1;
    }

    return 0;
}

static int mkdir_p(const char *path) {
    char tmp[512];
    size_t len = strlen(path);

    if (len == 0 || len >= sizeof(tmp)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    memcpy(tmp, path, len + 1);

    for (char *p = tmp + 1; *p; ++p) {
        if (*p != '/') {
            continue;
        }

        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
            return -1;
        }
        *p = '/';
    }

    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        return -1;
    }

    return 0;
}

/* Provision the keystore passphrase used to seal the transport ML-KEM key
 * (and, for operator nodes, the BLS seed) at rest on public-profile chains
 * (AUD-0029). If the file already exists it is reused unchanged across
 * restarts (the transport identity must stay stable). Otherwise a per-node
 * 256-bit random passphrase is generated, hex-encoded, and written 0600 —
 * no default secret is ever shipped in the image. */
static int ensure_keystore_passphrase(const char *path) {
    if (access(path, F_OK) == 0) {
        return 0;
    }

    unsigned char raw[32];
    FILE *rnd = fopen("/dev/urandom", "rb");
    if (!rnd) {
        perror("fopen /dev/urandom");
        return -1;
    }
    size_t got = fread(raw, 1, sizeof(raw), rnd);
    fclose(rnd);
    if (got != sizeof(raw)) {
        fprintf(stderr, "short read from /dev/urandom while generating keystore passphrase\n");
        return -1;
    }

    static const char hexd[] = "0123456789abcdef";
    char hex[sizeof(raw) * 2 + 1];
    for (size_t i = 0; i < sizeof(raw); ++i) {
        hex[2 * i] = hexd[(raw[i] >> 4) & 0x0f];
        hex[2 * i + 1] = hexd[raw[i] & 0x0f];
    }
    hex[sizeof(raw) * 2] = '\0';

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        perror("open keystore passphrase file");
        return -1;
    }
    size_t to_write = strlen(hex);
    ssize_t written = write(fd, hex, to_write);
    if (written < 0 || (size_t)written != to_write) {
        perror("write keystore passphrase file");
        close(fd);
        return -1;
    }
    if (close(fd) != 0) {
        perror("close keystore passphrase file");
        return -1;
    }
    return 0;
}

static int run_and_wait(char *const argv[], const char *label) {
    pid_t pid = fork();

    if (pid < 0) {
        perror("fork");
        return -1;
    }

    if (pid == 0) {
        execv(argv[0], argv);
        perror("execv");
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("waitpid");
        return -1;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "%s failed with status %d\n", label, status);
        return -1;
    }

    return 0;
}

static int verify_protocore_release(void) {
    const char *digest = getenv("PROTOCORE_EXPECTED_DIGEST");
    const char *digest_file = getenv("PROTOCORE_EXPECTED_DIGEST_FILE");
    int has_digest = digest && digest[0];
    int has_digest_file = digest_file && digest_file[0];

    if (has_digest && has_digest_file) {
        fprintf(stderr, "set only one of PROTOCORE_EXPECTED_DIGEST or PROTOCORE_EXPECTED_DIGEST_FILE\n");
        return -1;
    }

    if (!has_digest && !has_digest_file) {
        return 0;
    }

    char *verify_argv[] = {
        "./protocore",
        "--output", "json",
        "release", "verify",
        has_digest ? "--digest" : "--digest-file",
        has_digest ? (char *)digest : (char *)digest_file,
        NULL,
    };

    return run_and_wait(verify_argv, "protocore release verify");
}

static int verify_provisioning_policy(void) {
    const char *expected_digest = getenv("PROTOCORE_EXPECTED_DIGEST");
    const char *expected_digest_file = getenv("PROTOCORE_EXPECTED_DIGEST_FILE");
    const char *enrollment_file = env_or_default("PROTOCORE_ENROLLMENT_FILE", "/var/lib/protocore/enrollment/enrollment.json");
    const char *require_enrollment = env_or_default("PROTOCORE_REQUIRE_ENROLLMENT", "false");
    const char *require_tpm_binding = env_or_default("PROTOCORE_REQUIRE_TPM_BINDING", "false");
    const char *tpm_quote_file = getenv("PROTOCORE_TPM_QUOTE_FILE");
    const char *tpm_event_log_file = getenv("PROTOCORE_TPM_EVENT_LOG_FILE");
    const char *tpm_sealed_bls_share_file = getenv("PROTOCORE_TPM_SEALED_BLS_SHARE_FILE");
    const char *dkg_transcript_file = getenv("PROTOCORE_DKG_TRANSCRIPT_FILE");
    const char *postgres_url = getenv("PROTOCORE_INDEXER_POSTGRES_URL");
    const char *postgres_url_file = getenv("PROTOCORE_INDEXER_POSTGRES_URL_FILE");

    if (reject_inline_secret_envs() != 0) {
        return -1;
    }

    const char *placeholder_checked[] = {
        "PROTOCORE_EXPECTED_DIGEST",
        "PROTOCORE_EXPECTED_DIGEST_FILE",
        "PROTOCORE_ENROLLMENT_FILE",
        "PROTOCORE_CHAIN_ID",
        "PROTOCORE_P2P_LISTEN",
        "PROTOCORE_RPC_LISTEN",
        "PROTOCORE_DISCOVERY",
        "PROTOCORE_GENESIS_TOML",
        "PROTOCORE_INDEXER_POSTGRES_URL",
        "PROTOCORE_INDEXER_POSTGRES_URL_FILE",
        "PROTOCORE_TPM_QUOTE_FILE",
        "PROTOCORE_TPM_EVENT_LOG_FILE",
        "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE",
        "PROTOCORE_DKG_TRANSCRIPT_FILE",
        NULL,
    };
    for (const char **name = placeholder_checked; *name; ++name) {
        if (reject_placeholder_env(*name) != 0) {
            return -1;
        }
    }

    if (expected_digest && expected_digest[0] && validate_hex_digest(expected_digest) != 0) {
        fprintf(stderr, "PROTOCORE_EXPECTED_DIGEST must be a 64-character SHA-256 hex digest\n");
        return -1;
    }
    if (expected_digest_file && expected_digest_file[0] &&
        require_readable_file(expected_digest_file, "PROTOCORE_EXPECTED_DIGEST_FILE") != 0) {
        return -1;
    }

    if (postgres_url && postgres_url[0] && postgres_url_file && postgres_url_file[0]) {
        fprintf(stderr, "set only one of PROTOCORE_INDEXER_POSTGRES_URL or PROTOCORE_INDEXER_POSTGRES_URL_FILE\n");
        return -1;
    }
    if (postgres_url && postgres_url[0] && strchr(postgres_url, '@')) {
        fprintf(stderr, "PROTOCORE_INDEXER_POSTGRES_URL appears to contain credentials; use PROTOCORE_INDEXER_POSTGRES_URL_FILE\n");
        return -1;
    }
    if (postgres_url_file && postgres_url_file[0] &&
        require_readable_file(postgres_url_file, "PROTOCORE_INDEXER_POSTGRES_URL_FILE") != 0) {
        return -1;
    }

    if (is_truthy(require_enrollment)) {
        if (require_readable_file(enrollment_file, "PROTOCORE_ENROLLMENT_FILE") != 0) {
            return -1;
        }
        if (!(expected_digest && expected_digest[0]) &&
            !(expected_digest_file && expected_digest_file[0])) {
            fprintf(stderr, "PROTOCORE_REQUIRE_ENROLLMENT requires a release digest or digest file\n");
            return -1;
        }
    }
    if (is_truthy(require_tpm_binding)) {
        if (require_readable_file(tpm_quote_file, "PROTOCORE_TPM_QUOTE_FILE") != 0 ||
            require_readable_file(tpm_event_log_file, "PROTOCORE_TPM_EVENT_LOG_FILE") != 0 ||
            require_readable_file(tpm_sealed_bls_share_file, "PROTOCORE_TPM_SEALED_BLS_SHARE_FILE") != 0 ||
            require_readable_file(dkg_transcript_file, "PROTOCORE_DKG_TRANSCRIPT_FILE") != 0) {
            return -1;
        }
        if (!is_truthy(require_enrollment)) {
            fprintf(stderr, "PROTOCORE_REQUIRE_TPM_BINDING requires PROTOCORE_REQUIRE_ENROLLMENT=true\n");
            return -1;
        }
    }

    return 0;
}

static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");

    if (!in) {
        perror("fopen source");
        return -1;
    }

    FILE *out = fopen(dst, "wb");

    if (!out) {
        perror("fopen destination");
        fclose(in);
        return -1;
    }

    char buf[8192];
    size_t n = 0;

    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            perror("fwrite");
            fclose(in);
            fclose(out);
            return -1;
        }
    }

    if (ferror(in)) {
        perror("fread");
        fclose(in);
        fclose(out);
        return -1;
    }

    fclose(in);
    fclose(out);
    return 0;
}

static void write_quoted(FILE *out, const char *value) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        switch (*p) {
            case '\\':
                fputs("\\\\", out);
                break;
            case '"':
                fputs("\\\"", out);
                break;
            case '\n':
                fputs("\\n", out);
                break;
            case '\r':
                fputs("\\r", out);
                break;
            case '\t':
                fputs("\\t", out);
                break;
            default:
                fputc(*p, out);
                break;
        }
    }
    fputc('"', out);
}

static void write_peer_list(FILE *out, const char *peers) {
    fputc('[', out);
    if (peers && peers[0]) {
        char buf[4096];
        size_t len = strlen(peers);
        if (len >= sizeof(buf)) {
            len = sizeof(buf) - 1;
        }
        memcpy(buf, peers, len);
        buf[len] = '\0';

        int first = 1;
        char *save = NULL;
        for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            while (*tok == ' ' || *tok == '\t') {
                tok++;
            }
            size_t tok_len = strlen(tok);
            while (tok_len > 0 && (tok[tok_len - 1] == ' ' || tok[tok_len - 1] == '\t')) {
                tok[--tok_len] = '\0';
            }
            if (!tok[0]) {
                continue;
            }
            if (!first) {
                fputs(", ", out);
            }
            write_quoted(out, tok);
            first = 0;
        }
    }
    fputc(']', out);
}

static int write_first_boot_config(const char *path, const char *passphrase_file) {
    const char *chain_id = env_or_default("PROTOCORE_CHAIN_ID", "69420");
    const char *p2p_listen = env_or_default("PROTOCORE_P2P_LISTEN", "/ip4/0.0.0.0/tcp/29898");
    const char *p2p_peers = getenv("PROTOCORE_P2P_PEERS");
    const char *discovery = env_or_default("PROTOCORE_DISCOVERY", "hybrid");
    const char *rpc_listen = env_or_default("PROTOCORE_RPC_LISTEN", "0.0.0.0:8545");
    const char *postgres_url = getenv("PROTOCORE_INDEXER_POSTGRES_URL");
    const char *postgres_url_file = getenv("PROTOCORE_INDEXER_POSTGRES_URL_FILE");
    char postgres_url_buf[4096];

    if ((!postgres_url || !postgres_url[0]) && postgres_url_file && postgres_url_file[0]) {
        if (read_file_trimmed(postgres_url_file, postgres_url_buf, sizeof(postgres_url_buf),
                              "PROTOCORE_INDEXER_POSTGRES_URL_FILE") != 0) {
            return -1;
        }
        postgres_url = postgres_url_buf;
    }

    int indexer_postgres = postgres_url && postgres_url[0];

    FILE *out = fopen(path, "wb");
    if (!out) {
        perror("fopen config");
        return -1;
    }

    fprintf(out,
            "# protocore node config - Monarch OS full node\n\n"
            "[node]\n"
            "mode = \"full\"\n\n"
            "[consensus]\n"
            "chain_id = %s\n"
            "round_duration_ms = 3000\n\n"
            "[p2p]\n"
            "listen = ",
            chain_id);
    write_quoted(out, p2p_listen);
    fputs("\npeers = ", out);
    write_peer_list(out, p2p_peers);
    fputs("\ndiscovery = ", out);
    write_quoted(out, discovery);
    fputs("\n\n[rpc]\n"
          "enabled = true\n"
          "public_profile_allow_self_signed = true\n"
          "listen = ",
          out);
    write_quoted(out, rpc_listen);
    fputs("\ndebug = false\n\n[indexer]\n", out);
    if (indexer_postgres) {
        fputs("enabled = true\nbackend = \"postgres\"\npostgres_url = ", out);
        write_quoted(out, postgres_url);
        fputc('\n', out);
    } else {
        fputs("enabled = false\n", out);
    }
    fputs("\n[keystore]\npassphrase_file = ", out);
    write_quoted(out, passphrase_file);
    fputc('\n', out);
    fputs("\n[retention]\narchive = false\nprune_period_blocks = 10000\n", out);

    if (fclose(out) != 0) {
        perror("fclose config");
        return -1;
    }
    return 0;
}

static void append_optional(char **argv, size_t *idx, const char *flag, const char *env_name) {
    const char *value = getenv(env_name);

    if (value && value[0]) {
        argv[(*idx)++] = (char *)flag;
        argv[(*idx)++] = (char *)value;
    }
}

int main(void) {
    const char *home = env_or_default("PROTOCORE_HOME", "/var/lib/protocore");
    const char *network = env_or_default("PROTOCORE_NETWORK", "testnet");
    const char *genesis = env_or_default("PROTOCORE_GENESIS_TOML", "./defaults/testnet/genesis.toml");
    char config_path[640];
    char genesis_path[640];

    if (mkdir_p(home) != 0) {
        perror("mkdir_p");
        return 1;
    }

    snprintf(config_path, sizeof(config_path), "%s/config.toml", home);
    snprintf(genesis_path, sizeof(genesis_path), "%s/genesis.toml", home);

    if (verify_provisioning_policy() != 0) {
        return 1;
    }
    if (verify_protocore_release() != 0) {
        return 1;
    }

    /* Resolve + provision the keystore passphrase. Operators mount their own
     * secret via PROTOCORE_KEYSTORE_PASSPHRASE_FILE (a file path; the inline
     * PROTOCORE_KEYSTORE_PASSPHRASE env stays rejected by
     * reject_inline_secret_envs). With no operator file, a per-node passphrase
     * is auto-generated under <home>/keystore and persisted on the STATE
     * partition so a default full-node image boots with no secret material. */
    char passphrase_path[640];
    const char *pp_file_env = getenv("PROTOCORE_KEYSTORE_PASSPHRASE_FILE");
    if (pp_file_env && pp_file_env[0]) {
        if (require_readable_file(pp_file_env, "PROTOCORE_KEYSTORE_PASSPHRASE_FILE") != 0) {
            return 1;
        }
        snprintf(passphrase_path, sizeof(passphrase_path), "%s", pp_file_env);
    } else {
        char keystore_dir[640];
        snprintf(keystore_dir, sizeof(keystore_dir), "%s/keystore", home);
        if (mkdir_p(keystore_dir) != 0) {
            perror("mkdir_p keystore");
            return 1;
        }
        snprintf(passphrase_path, sizeof(passphrase_path), "%s/keystore/passphrase", home);
        if (ensure_keystore_passphrase(passphrase_path) != 0) {
            return 1;
        }
    }

    int first_boot = access(config_path, F_OK) != 0;
    if (first_boot) {
        char *init_argv[] = {
            "./protocore",
            "--home", (char *)home,
            "--network", (char *)network,
            "--output", "json",
            "--yes",
            "init", (char *)network,
            "--no-operator",
            "--force",
            NULL,
        };

        if (run_and_wait(init_argv, "protocore init") != 0) {
            return 1;
        }
        if (write_first_boot_config(config_path, passphrase_path) != 0) {
            return 1;
        }
    }

    /* Dynamic genesis resolution from the public chain-registry. The image
     * bakes WHO to trust (the registry path) not WHAT to run (no genesis hash),
     * so a re-genesis is picked up automatically on a fresh boot. The fetch is
     * done IN the binary (in-process TLS) — the hardened rootfs has no HTTP
     * client. Only on first boot (genesis.toml absent); a running node's
     * genesis is never re-fetched. */
    if (access(genesis_path, F_OK) != 0) {
        const char *registry_network =
            env_or_default("PROTOCORE_REGISTRY_NETWORK", "testnet-69420");
        char *resolve_argv[] = {
            "./protocore",
            "--home", (char *)home,
            "--network", (char *)network,
            "--output", "json",
            "genesis", "resolve",
            "--registry-network", (char *)registry_network,
            "--out", genesis_path,
            "--write-peers", config_path,
            NULL,
        };
        if (run_and_wait(resolve_argv, "protocore genesis resolve") != 0) {
            /* Resolve failed (registry unreachable / hash mismatch / timeout).
             * Fall back to the BAKED genesis LOUDLY — it may be STALE relative
             * to the live chain. PROTOCORE_GENESIS_FALLBACK=fail refuses the
             * fallback (mainnet fail-closed posture). */
            const char *fallback =
                env_or_default("PROTOCORE_GENESIS_FALLBACK", "baked");
            if (strcmp(fallback, "fail") == 0) {
                fprintf(stderr,
                        "FATAL: dynamic genesis resolve failed and "
                        "PROTOCORE_GENESIS_FALLBACK=fail; refusing to boot.\n");
                return 1;
            }
            fprintf(stderr,
                    "WARNING: dynamic genesis resolve failed; falling back to "
                    "the BAKED genesis (may be STALE). Set "
                    "PROTOCORE_GENESIS_FALLBACK=fail to refuse.\n");
            if (access(genesis, R_OK) != 0) {
                fprintf(stderr, "FATAL: no baked genesis fallback at %s\n",
                        genesis);
                return 1;
            }
            if (copy_file(genesis, genesis_path) != 0) {
                return 1;
            }
        }
    }

    char *start_argv[32];
    size_t idx = 0;

    start_argv[idx++] = "./protocore";
    start_argv[idx++] = "--home";
    start_argv[idx++] = (char *)home;
    start_argv[idx++] = "--network";
    start_argv[idx++] = (char *)network;
    start_argv[idx++] = "--log-format";
    start_argv[idx++] = "json";
    start_argv[idx++] = "--output";
    start_argv[idx++] = "json";
    start_argv[idx++] = "start";

    append_optional(start_argv, &idx, "--p2p-listen", "PROTOCORE_P2P_LISTEN");
    append_optional(start_argv, &idx, "--discovery", "PROTOCORE_DISCOVERY");
    append_optional(start_argv, &idx, "--zkml-vkey-hash", "PROTOCORE_ZKML_VKEY_HASH");
    append_optional(start_argv, &idx, "--sp1-helios-vkey-hash", "PROTOCORE_SP1_HELIOS_VKEY_HASH");
    start_argv[idx] = NULL;

    execv(start_argv[0], start_argv);
    perror("execv");
    return 127;
}
