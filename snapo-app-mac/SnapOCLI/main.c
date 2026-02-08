#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *kHelperRelativeExecutable =
    "Helpers/Snap-O Network Inspector.app/Contents/MacOS/Snap-O Network Inspector";

static int resolve_helper_executable(const char *argv0, char *out, size_t out_size) {
  char resolved_executable[PATH_MAX];
  char *last_slash = NULL;
  int written = 0;

  if (realpath(argv0, resolved_executable) == NULL) {
    return -1;
  }

  last_slash = strrchr(resolved_executable, '/');
  if (last_slash == NULL) {
    return -1;
  }
  *last_slash = '\0';

  last_slash = strrchr(resolved_executable, '/');
  if (last_slash == NULL) {
    return -1;
  }
  *last_slash = '\0';

  written = snprintf(out, out_size, "%s/%s", resolved_executable, kHelperRelativeExecutable);
  if (written < 0 || (size_t)written >= out_size) {
    return -1;
  }

  return 0;
}

int main(int argc, char *argv[]) {
  char helper_executable[PATH_MAX];
  char **child_argv = NULL;
  int i = 0;

  if (resolve_helper_executable(argv[0], helper_executable, sizeof(helper_executable)) != 0) {
    fprintf(stderr, "snapo: failed to resolve helper executable path\n");
    return 1;
  }

  child_argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "snapo: failed to allocate argument buffer\n");
    return 1;
  }

  child_argv[0] = helper_executable;
  for (i = 1; i < argc; i++) {
    child_argv[i] = argv[i];
  }
  child_argv[argc] = NULL;

  execv(helper_executable, child_argv);
  perror("snapo: failed to launch helper");
  free(child_argv);
  return 1;
}
