APP_BUNDLE_NAME := Snap-O\ Network\ Inspector.app
DEBUG_APP := build/macos/main/app/$(APP_BUNDLE_NAME)
RELEASE_APP := build/macos/main-release/app/$(APP_BUNDLE_NAME)
NODE_MODULES_STAMP := node_modules/.package-lock.json
NODE_MODULES_TOOLS := node_modules/.bin/tsc node_modules/electron/package.json
PACKAGE_SOURCE_PATHS := $(shell find electron resources scripts src -type d -o -type f)
PACKAGE_INPUTS := \
	Makefile \
	../VERSION \
	.npmrc \
	index.html \
	package-lock.json \
	package.json \
	tsconfig.electron.json \
	tsconfig.json \
	vite.config.ts \
	$(PACKAGE_SOURCE_PATHS)

.PHONY: package-mac-if-needed package-mac-release-if-needed

package-mac-if-needed: $(DEBUG_APP)

package-mac-release-if-needed: $(RELEASE_APP)

$(DEBUG_APP): $(PACKAGE_INPUTS) $(NODE_MODULES_TOOLS)
	npm run package:mac

$(RELEASE_APP): $(PACKAGE_INPUTS) $(NODE_MODULES_TOOLS)
	npm run package:mac:release

$(NODE_MODULES_STAMP): .npmrc package-lock.json package.json
	npm ci --include=dev

$(NODE_MODULES_TOOLS): $(NODE_MODULES_STAMP)
	@test -e "$@" || npm ci --include=dev
