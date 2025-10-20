#!/bin/bash

set -ef

GROUP=

group() {
	endgroup
	echo "::group::  $1"
	GROUP=1
}

endgroup() {
	if [ -n "$GROUP" ]; then
		echo "::endgroup::"
	fi
	GROUP=
}

trap 'endgroup' ERR

group "bash setup.sh"
# snapshot containers don't ship with the SDK to save bandwidth
# run setup.sh to download and extract the SDK
[ ! -f setup.sh ] || bash setup.sh
endgroup

FEEDNAME="${FEEDNAME:-action}"
BUILD_LOG="${BUILD_LOG:-1}"

# Set download mirror to include iopsys mirror if not specified
if [ -z "$DOWNLOAD_MIRROR" ]; then
	export DOWNLOAD_MIRROR="https://download.iopsys.eu/iopsys/mirror/"
fi

if [ -n "$KEY_BUILD" ]; then
	echo "$KEY_BUILD" > key-build
	CONFIG_SIGNED_PACKAGES="y"
fi

if [ -n "$PRIVATE_KEY" ]; then
	echo "$PRIVATE_KEY" > private-key.pem
	CONFIG_SIGNED_PACKAGES="y"
fi

if [ -z "$NO_DEFAULT_FEEDS" ]; then
	sed \
		-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
		feeds.conf.default > feeds.conf
fi

echo "src-link $FEEDNAME /feed/" >> feeds.conf

ALL_CUSTOM_FEEDS="$FEEDNAME "

# Fix for EXTRA_FEEDS processing with proper path handling
#shellcheck disable=SC2153
for EXTRA_FEED in $EXTRA_FEEDS; do
	# Check if EXTRA_FEED contains pipe separator (new format)
	if [[ "$EXTRA_FEED" == *"|"* ]]; then
		# Extract components: src-type|feedname|path
		FEED_TYPE=$(echo "$EXTRA_FEED" | cut -d'|' -f1)
		FEED_NAME=$(echo "$EXTRA_FEED" | cut -d'|' -f2)
		FEED_PATH=$(echo "$EXTRA_FEED" | cut -d'|' -f3)
		
		# Handle workspace path resolution
		if [[ "$FEED_PATH" == *"/github/workspace/"* ]] || [[ "$FEED_PATH" == *"github.workspace"* ]]; then
			# Convert GitHub workspace paths to container paths
			# The main feed is mounted at /feed/, so any additional feed should be at /feed/../{feedname}
			FEED_PATH="/feed/../${FEED_NAME}"
		elif [[ "$FEED_PATH" == *"/workspace/"* ]] || [[ "$FEED_PATH" == *"workspace"* ]]; then
			# Handle other workspace path variations
			FEED_PATH="/feed/../${FEED_NAME}"
		fi
		
		# Write the feed line to feeds.conf
		echo "$FEED_TYPE $FEED_NAME $FEED_PATH" >> feeds.conf
		ALL_CUSTOM_FEEDS+="$FEED_NAME "
	else
		# Legacy format - assume it's just a feed name
		echo "src-link $EXTRA_FEED /feed/../$EXTRA_FEED" >> feeds.conf
		ALL_CUSTOM_FEEDS+="$EXTRA_FEED "
	fi
done

group "feeds.conf"
cat feeds.conf
endgroup

# Verify that custom feed paths exist if specified
for FEED in $ALL_CUSTOM_FEEDS; do
	if [[ "$FEED" != "$FEEDNAME" ]]; then
		FEED_DIR="/feed/../${FEED}"
		if [ ! -d "$FEED_DIR" ]; then
			echo "Warning: $FEED feed directory not found at $FEED_DIR"
			echo "Available directories in /feed/../:"
			ls -la /feed/../ || true
		else
			echo "✓ $FEED feed directory found at $FEED_DIR"
		fi
	fi
done

group "feeds update -a"
./scripts/feeds update -a
endgroup

group "make defconfig"
make defconfig
endgroup

if [ -z "$PACKAGES" ]; then
	# compile all packages in feed
	for FEED in $ALL_CUSTOM_FEEDS; do
		group "feeds install -p $FEED -f -a"
		./scripts/feeds install -p "$FEED" -f -a
  		if [[ "$GOPACKAGELATEST" =~ ^(true|yes|1)$ ]]; then
  			rm -rf feeds/packages/lang/golang
			git clone https://github.com/kmoz000/packages_lang_golang -b 24.x feeds/packages/lang/golang
  		fi
		endgroup
	done

	RET=0

	make \
		BUILD_LOG="$BUILD_LOG" \
		CONFIG_SIGNED_PACKAGES="$CONFIG_SIGNED_PACKAGES" \
		IGNORE_ERRORS="$IGNORE_ERRORS" \
		CONFIG_AUTOREMOVE=y \
		V="$V" \
		-j "$(nproc)" || RET=$?
else
	# compile specific packages with checks
	for PKG in $PACKAGES; do
		for FEED in $ALL_CUSTOM_FEEDS; do
			group "feeds install -p $FEED -f $PKG"
			./scripts/feeds install -p "$FEED" -f "$PKG"
			endgroup
		done
		if [[ "$GOPACKAGELATEST" =~ ^(true|yes|1)$ ]]; then
  			rm -rf feeds/packages/lang/golang
			git clone https://github.com/kmoz000/packages_lang_golang -b 24.x feeds/packages/lang/golang
  		fi
		group "make package/$PKG/download"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/download" V=s
		endgroup

		group "make package/$PKG/check"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/check" V=s 2>&1 | \
				tee logtmp
		endgroup

		RET=${PIPESTATUS[0]}

		if [ "$RET" -ne 0 ]; then
			echo_red   "=> Package check failed: $RET)"
			exit "$RET"
		fi

		badhash_msg="PKG_HASH does not match "
		badhash_msg+="|PKG_HASH uses deprecated hash,"
		badhash_msg+="|PKG_HASH is missing,"
		if grep -qE "$badhash_msg" logtmp; then
			echo "Package HASH check failed"
			exit 1
		fi

		PATCHES_DIR=$(find /feed -path "*/$PKG/patches")
		if [ -d "$PATCHES_DIR" ] && [ -z "$NO_REFRESH_CHECK" ]; then
			group "make package/$PKG/refresh"
			make \
				BUILD_LOG="$BUILD_LOG" \
				IGNORE_ERRORS="$IGNORE_ERRORS" \
				"package/$PKG/refresh" V=s
			endgroup

			if ! git -C "$PATCHES_DIR" diff --quiet -- .; then
				echo "Dirty patches detected, please refresh and review the diff"
				git -C "$PATCHES_DIR" checkout -- .
				exit 1
			fi

			group "make package/$PKG/clean"
			make \
				BUILD_LOG="$BUILD_LOG" \
				IGNORE_ERRORS="$IGNORE_ERRORS" \
				"package/$PKG/clean" V=s
			endgroup
		fi

		FILES_DIR=$(find /feed -path "*/$PKG/files")
		if [ -d "$FILES_DIR" ] && [ -z "$NO_SHFMT_CHECK" ]; then
			find "$FILES_DIR" -name "*.init" -exec shfmt -w -sr -s '{}' \;
			if ! git -C "$FILES_DIR" diff --quiet -- .; then
				echo "init script must be formatted. Please run through shfmt -w -sr -s"
				git -C "$FILES_DIR" checkout -- .
				exit 1
			fi
		fi

	done

	make \
		-f .config \
		-f tmp/.packagedeps \
		-f <(echo "\$(info \$(sort \$(package-y) \$(package-m)))"; echo -en "a:\n\t@:") \
			| tr ' ' '\n' > enabled-package-subdirs.txt

	RET=0

	for PKG in $PACKAGES; do
		if ! grep -m1 -qE "(^|/)$PKG$" enabled-package-subdirs.txt; then
			echo "::warning file=$PKG::Skipping $PKG due to unsupported architecture"
			continue
		fi

		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			CONFIG_AUTOREMOVE=y \
			V="$V" \
			-j "$(nproc)" \
			"package/$PKG/compile" || {
				RET=$?
				break
			}
	done
fi

if [ "$INDEX" = '1' ];then
	group "make package/index"
	make package/index
	endgroup
fi

if [ -d bin/ ]; then
	mv bin/ /artifacts/
fi

if [ -d logs/ ]; then
	mv logs/ /artifacts/
fi

exit "$RET"
