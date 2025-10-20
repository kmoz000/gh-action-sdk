ARG CONTAINER=ghcr.io/openwrt/sdk
ARG ARCH=mips_24kc
FROM $CONTAINER:$ARCH

LABEL "com.github.actions.name"="OpenWrt SDK"
# Update the package list and install jq using opkg
ADD entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
