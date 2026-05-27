#include <errno.h>
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

static int write_first_boot_config(const char *path) {
    const char *chain_id = env_or_default("PROTOCORE_CHAIN_ID", "69420");
    const char *p2p_listen = env_or_default("PROTOCORE_P2P_LISTEN", "/ip4/0.0.0.0/tcp/29898");
    const char *p2p_peers = getenv("PROTOCORE_P2P_PEERS");
    const char *discovery = env_or_default("PROTOCORE_DISCOVERY", "hybrid");
    const char *rpc_listen = env_or_default("PROTOCORE_RPC_LISTEN", "0.0.0.0:8545");
    const char *postgres_url = getenv("PROTOCORE_INDEXER_POSTGRES_URL");
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

    if (verify_protocore_release() != 0) {
        return 1;
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
        if (write_first_boot_config(config_path) != 0) {
            return 1;
        }
    }

    if (access(genesis_path, F_OK) != 0 && access(genesis, R_OK) == 0) {
        if (copy_file(genesis, genesis_path) != 0) {
            return 1;
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
