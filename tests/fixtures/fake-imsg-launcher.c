#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    static const char driver_name[] = "/fake-imsg-driver.sh";
    static char bash_path[] = "/bin/bash";

    if (argc < 1 || argv[0] == NULL) {
        fputs("fake imsg launcher has no executable path\n", stderr);
        return 126;
    }

    const char *separator = strrchr(argv[0], '/');
    if (argv[0][0] != '/' || separator == NULL) {
        fputs("fake imsg launcher path is not absolute\n", stderr);
        return 126;
    }

    size_t directory_length = (size_t)(separator - argv[0]);
    if (directory_length + sizeof(driver_name) > PATH_MAX) {
        fputs("fake imsg driver path is too long\n", stderr);
        return 126;
    }

    char driver_path[PATH_MAX];
    memcpy(driver_path, argv[0], directory_length);
    memcpy(driver_path + directory_length, driver_name, sizeof(driver_name));

    char **forwarded = calloc((size_t)argc + 2, sizeof(*forwarded));
    if (forwarded == NULL) {
        fputs("fake imsg launcher could not allocate arguments\n", stderr);
        return 126;
    }
    forwarded[0] = bash_path;
    forwarded[1] = driver_path;
    for (int index = 1; index < argc; index++) {
        forwarded[index + 1] = argv[index];
    }

    execv(bash_path, forwarded);
    int saved_errno = errno;
    fprintf(stderr, "fake imsg launcher could not execute its driver: %s\n", strerror(saved_errno));
    free(forwarded);
    return saved_errno == ENOENT ? 127 : 126;
}
