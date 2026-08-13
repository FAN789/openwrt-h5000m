#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_DIR="${1:-${OPENWRT_BUILD_DIR:-}}"
PROJECTS_DIR="${H5000M_PROJECTS_DIR:-$(dirname "${ROOT_DIR}")}"

if [ -z "${OPENWRT_DIR}" ] || [ ! -d "${OPENWRT_DIR}/.git" ]; then
	echo "Usage: $0 /path/to/pinned-openwrt-source" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "${ROOT_DIR}/configs/integrated-daed.env"

expected_feed_commit() {
	case "$1" in
		packages) echo "${PACKAGES_FEED_COMMIT}" ;;
		luci) echo "${LUCI_FEED_COMMIT}" ;;
		routing) echo "${ROUTING_FEED_COMMIT}" ;;
		telephony) echo "${TELEPHONY_FEED_COMMIT}" ;;
		video) echo "${VIDEO_FEED_COMMIT}" ;;
		daed) echo "${DAED_FEED_COMMIT}" ;;
		qmodem) echo "${QMODEM_FEED_COMMIT}" ;;
	esac
}

actual_commit="$(git -C "${OPENWRT_DIR}" rev-parse HEAD)"
[ "${actual_commit}" = "${OPENWRT_COMMIT}" ] || {
	echo "OpenWrt source is ${actual_commit}, expected ${OPENWRT_COMMIT}." >&2
	exit 1
}

for feed in packages luci routing telephony video daed qmodem; do
	actual="$(git -C "${OPENWRT_DIR}/feeds/${feed}" rev-parse HEAD 2>/dev/null || true)"
	expected="$(expected_feed_commit "${feed}")"
	[ "${actual}" = "${expected}" ] || {
		echo "Feed ${feed} is ${actual:-missing}, expected ${expected}." >&2
		exit 1
	}
done

apply_once() {
	local patch_file="$1"
	if patch -d "${OPENWRT_DIR}" -p1 --dry-run --forward <"${patch_file}" >/dev/null 2>&1; then
		patch -d "${OPENWRT_DIR}" -p1 --forward <"${patch_file}"
	elif patch -d "${OPENWRT_DIR}" -p1 --dry-run --reverse <"${patch_file}" >/dev/null 2>&1; then
		printf 'Already applied: %s\n' "$(basename "${patch_file}")"
	else
		echo "Patch does not apply cleanly: ${patch_file}" >&2
		exit 1
	fi
}

for patch_name in \
	daed-source-layout.patch \
	daed-reproducible.patch \
	daed-package.patch \
	daed-runtime.patch \
	luci-app-daed-dashboard.patch \
	h5000m-fan-cooling-map.patch; do
	apply_once "${ROOT_DIR}/configs/${patch_name}"
done

install -d "${OPENWRT_DIR}/feeds/daed/daed/files"
install -m 0644 "${ROOT_DIR}/configs/daed-web-defaults.patch" \
	"${OPENWRT_DIR}/feeds/daed/daed/files/h5000m-web-defaults.patch"
install -m 0644 "${ROOT_DIR}/configs/daed-runtime-optimizations.patch" \
	"${OPENWRT_DIR}/feeds/daed/daed/files/h5000m-runtime-optimizations.patch"

install -d "${OPENWRT_DIR}/package/h5000m-custom"
rsync -a --delete \
	"${PROJECTS_DIR}/luci-app-daed-h5000m/openwrt/h5000m-daed-defaults/" \
	"${OPENWRT_DIR}/package/h5000m-custom/h5000m-daed-defaults/"
rsync -a --delete \
	"${PROJECTS_DIR}/luci-app-daed-h5000m/openwrt/luci-app-daed-geodata/" \
	"${OPENWRT_DIR}/package/h5000m-custom/luci-app-daed-geodata/"
rsync -a --delete --exclude='.git/' --exclude='artifacts/' --exclude='dist/' \
	"${PROJECTS_DIR}/luci-app-h5000m-fancontrol/" \
	"${OPENWRT_DIR}/package/h5000m-custom/luci-app-h5000m-fancontrol/"
rsync -a --delete --exclude='.git/' --exclude='artifacts/' --exclude='dist/' \
	"${PROJECTS_DIR}/luci-app-h5000m-netmode/" \
	"${OPENWRT_DIR}/package/h5000m-custom/luci-app-h5000m-netmode/"
rsync -a --delete --exclude='.git/' --exclude='artifacts/' --exclude='dist*/' \
	"${PROJECTS_DIR}/luci-app-mt5700m/luci-app-mt5700m/" \
	"${OPENWRT_DIR}/package/h5000m-custom/luci-app-mt5700m/"

install -d "${OPENWRT_DIR}/files"
rsync -a --delete "${ROOT_DIR}/official-base-files/" "${OPENWRT_DIR}/files/"
install -m 0644 "${ROOT_DIR}/integrated-daed-files/etc/h5000m-daed-build" \
	"${OPENWRT_DIR}/files/etc/h5000m-daed-build"
install -m 0644 "${ROOT_DIR}/configs/integrated-daed.seed" "${OPENWRT_DIR}/.config"

make -C "${OPENWRT_DIR}" defconfig
grep -qx "CONFIG_VERSION_CODE=\"${OPENWRT_REVISION}\"" "${OPENWRT_DIR}/.config"
grep -qx 'CONFIG_KERNEL_DEBUG_INFO_BTF=y' "${OPENWRT_DIR}/.config"
grep -qx 'CONFIG_KERNEL_XDP_SOCKETS=y' "${OPENWRT_DIR}/.config"

echo "Prepared H5000M daed source at ${OPENWRT_REVISION}."
