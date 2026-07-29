#!/bin/bash

set -euo pipefail

fail() {
    printf 'release contract error: %s\n' "$*" >&2
    exit 1
}

script_dir="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd
)"
repository_root="$(
    cd -- "${script_dir}/.."
    pwd
)"
package_script="${script_dir}/package-release.sh"
workflow="${repository_root}/.github/workflows/release.yml"
settings_file="$(
    mktemp "${TMPDIR:-/tmp}/llamadock-settings.XXXXXX"
)"

cleanup() {
    if [[ -f "${settings_file:-}" ]]; then
        rm -f -- "${settings_file}"
    fi
}
trap cleanup EXIT

bash -n "${package_script}"
[[ -f "${workflow}" ]] \
    || fail "release workflow is missing"

for required_text in \
    'Developer ID Application' \
    'notarytool' \
    'stapler validate' \
    'spctl --assess' \
    'shasum -a 256' \
    'ARCHS=arm64'
do
    grep -Fq "${required_text}" "${package_script}" \
        || fail "package script is missing: ${required_text}"
done

for required_text in \
    'workflow_dispatch:' \
    'tags:' \
    'Scripts/package-release.sh' \
    'actions/upload-artifact@v7.0.1' \
    "if: github.event_name == 'push'" \
    'gh release create' \
    'APPLE_CERTIFICATE_BASE64' \
    'APPLE_APP_SPECIFIC_PASSWORD'
do
    grep -Fq "${required_text}" "${workflow}" \
        || fail "release workflow is missing: ${required_text}"
done

cd -- "${repository_root}"
xcodebuild \
    -project Llamadock.xcodeproj \
    -scheme Llamadock \
    -configuration Release \
    -showBuildSettings \
    >"${settings_file}"

grep -Eq '^[[:space:]]*ENABLE_APP_SANDBOX = NO$' \
    "${settings_file}" \
    || fail "Release must explicitly disable App Sandbox"
grep -Eq '^[[:space:]]*ENABLE_HARDENED_RUNTIME = YES$' \
    "${settings_file}" \
    || fail "Release must enable Hardened Runtime"
grep -Eq '^[[:space:]]*MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+$' \
    "${settings_file}" \
    || fail "Release must declare a semantic MARKETING_VERSION"
grep -Eq '^[[:space:]]*ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon$' \
    "${settings_file}" \
    || fail "Release must compile the AppIcon asset"

printf 'Release contract verified.\n'
