# Source this after defining APP_DIR.
# Compile each suite in one pass. Keep assertions enabled with -Onone.
# Swift checks source and dependency contents before reusing cached output.
swiftc_for_tests() {
  printf 'Compile standalone tests\n'
  /usr/bin/time -p xcrun swiftc -whole-module-optimization -Onone \
    -explicit-module-build -cache-compile-job -Rcache-compile-job \
    -cas-path "${SNAPO_DERIVED_DATA:-"$APP_DIR/.build/tests"}/CompilationCache.noindex/builtin" "$@"
}

run_test() {
  printf 'Run %s\n' "$(basename "$1")"
  /usr/bin/time -p "$@"
}
