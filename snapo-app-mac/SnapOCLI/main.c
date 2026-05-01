#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *kHelperRelativeExecutable =
    "Helpers/Snap-O Network Inspector.app/Contents/MacOS/Snap-O Network Inspector";
static const char *kCliEntrypointRelativePath =
    "Helpers/Snap-O Network Inspector.app/Contents/Resources/app/dist-electron/electron/cli-entry.js";

static int resolve_bundle_relative_path(const char *argv0, const char *relative_path, char *out,
                                        size_t out_size) {
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

  written = snprintf(out, out_size, "%s/%s", resolved_executable, relative_path);
  if (written < 0 || (size_t)written >= out_size) {
    return -1;
  }

  return 0;
}

int main(int argc, char *argv[]) {
  char helper_executable[PATH_MAX];
  char cli_entrypoint[PATH_MAX];
  char **child_argv = NULL;
  int i = 0;

  if (resolve_bundle_relative_path(argv[0], kHelperRelativeExecutable, helper_executable,
                                   sizeof(helper_executable)) != 0) {
    fprintf(stderr, "snapo: failed to resolve helper executable path\n");
    return 1;
  }

  if (resolve_bundle_relative_path(argv[0], kCliEntrypointRelativePath, cli_entrypoint,
                                   sizeof(cli_entrypoint)) != 0) {
    fprintf(stderr, "snapo: failed to resolve cli entrypoint path\n");
    return 1;
  }

  child_argv = (char **)calloc((size_t)argc + 2, sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "snapo: failed to allocate argument buffer\n");
    return 1;
  }

  if (setenv("ELECTRON_RUN_AS_NODE", "1", 1) != 0) {
    perror("snapo: failed to set ELECTRON_RUN_AS_NODE");
    free(child_argv);
    return 1;
  }

  child_argv[0] = helper_executable;
  child_argv[1] = cli_entrypoint;
  for (i = 1; i < argc; i++) {
    child_argv[i + 1] = argv[i];
  }
  child_argv[argc + 1] = NULL;

  execv(helper_executable, child_argv);
  perror("snapo: failed to launch helper");
  free(child_argv);
  return 1;
}
