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

static int run_and_wait(char *const argv[]) {
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
        fprintf(stderr, "protocore init failed with status %d\n", status);
        return -1;
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

    if (access(config_path, F_OK) != 0) {
        char *init_argv[] = {
            "./protocore",
            "--home", (char *)home,
            "--network", (char *)network,
            "--output", "json",
            "--yes",
            "init", (char *)network,
            "--no-validator",
            "--force",
            NULL,
        };

        if (run_and_wait(init_argv) != 0) {
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
