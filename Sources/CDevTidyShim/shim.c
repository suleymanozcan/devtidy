#include "CDevTidyShim.h"
#include <fcntl.h>
int devtidy_open_dir_abs(const char *path) {
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
}
int devtidy_openat_dir(int dirfd, const char *name) {
    return openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
}
int devtidy_fstatat_nofollow(int dirfd, const char *name, struct stat *st) {
    return fstatat(dirfd, name, st, AT_SYMLINK_NOFOLLOW_ANY);
}
