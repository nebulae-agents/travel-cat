/* Test-only app launcher. Paths are supplied at compilation for one isolated run. */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ACCEPTANCE_ROOT
#error ACCEPTANCE_ROOT must name the prepared isolated root
#endif
#ifndef ACCEPTANCE_EXECUTABLE
#error ACCEPTANCE_EXECUTABLE must name the copied application executable
#endif

int main(int argc, char **argv) {
    (void)argc;
    char resolved[PATH_MAX];
    struct stat root_status;
    const char *prefix = "/private/tmp/travelcat-native-acceptance-";
    if (!realpath(ACCEPTANCE_ROOT, resolved)
            || strcmp(resolved, ACCEPTANCE_ROOT) != 0
            || strncmp(resolved, prefix, strlen(prefix)) != 0
            || strchr(resolved + strlen(prefix), '/') != NULL
            || lstat(resolved, &root_status) != 0
            || !S_ISDIR(root_status.st_mode)
            || root_status.st_uid != getuid()
            || (root_status.st_mode & 0777) != 0700) {
        fputs("invalid isolated acceptance root\n", stderr);
        return 73;
    }
    if (setenv("TRAVEL_CAT_DATA", resolved, 1) != 0) return 74;

    char proof_path[PATH_MAX];
    if (snprintf(proof_path, sizeof proof_path, "%s/launch-proof.jsonl", resolved)
            >= (int)sizeof proof_path) return 74;
    int proof = open(proof_path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0600);
    struct stat proof_status;
    if (proof < 0) return 74;
    if (fstat(proof, &proof_status) != 0
            || !S_ISREG(proof_status.st_mode) || proof_status.st_nlink != 1
            || proof_status.st_uid != getuid()
            || (proof_status.st_mode & 0777) != 0600) {
        close(proof);
        return 74;
    }
    char row[128];
    int length = snprintf(row, sizeof row,
        "{\"forcedIsolatedRoot\":true,\"processID\":%d}\n", getpid());
    if (length < 0 || length >= (int)sizeof row || write(proof, row, length) != length) {
        close(proof);
        return 74;
    }
    close(proof);
    argv[0] = ACCEPTANCE_EXECUTABLE;
    execv(ACCEPTANCE_EXECUTABLE, argv);
    perror("isolated acceptance exec");
    return 74;
}
