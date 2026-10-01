# Source this after defining APP_DIR and TEST_DIR.
# Reuse the app's locked package versions and compiled test dependencies.
BUILD_DIR=${SNAPO_DERIVED_DATA:-"$TEST_DIR/xcode"}
CONFIGURATION=${SNAPO_TEST_CONFIGURATION:-Local}
if [ -z "${SNAPO_DERIVED_DATA:-}" ]; then
  xcodebuild -quiet -project "$APP_DIR/Snap-O.xcodeproj" -scheme Snap-O \
    -configuration "$CONFIGURATION" -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
fi
PRODUCTS="$BUILD_DIR/Build/Products/$CONFIGURATION"
export LLVM_PROFILE_FILE="$TEST_DIR/%m.profraw"

# Xcode shares these frameworks between the application and its test bundle.
# Link the same copies so dependency overrides reach the code under test.
swiftc_with_test_dependencies() {
  for framework in "$PRODUCTS/PackageFrameworks/"*.framework; do
    case "$framework" in
      *TestSupport.framework) continue ;;
    esac
    set -- "$@" -framework "$(basename "$framework" .framework)"
  done
  xcrun swiftc -profile-generate -I "$PRODUCTS" \
    -F "$PRODUCTS/PackageFrameworks" \
    -Xlinker -rpath -Xlinker "$PRODUCTS/PackageFrameworks" "$@"
}
