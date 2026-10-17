#ifndef CDEVTIDYSHIM_H
#define CDEVTIDYSHIM_H
#include <sys/stat.h>
/// open(path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC); -1 + errno on failure. Rejects a symlink at ANY component.
int devtidy_open_dir_abs(const char *path);
/// openat(dirfd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC). `name` is one path component.
int devtidy_openat_dir(int dirfd, const char *name);
/// fstatat(dirfd, name, st, AT_SYMLINK_NOFOLLOW_ANY).
int devtidy_fstatat_nofollow(int dirfd, const char *name, struct stat *st);
#endif
