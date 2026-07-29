#!/bin/bash

set -euo pipefail

fail() {
    printf 'release error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || fail "required command is unavailable: $1"
}

: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer Team ID.}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to a validated notarytool profile.}"

require_command codesign
require_command ditto
require_command lipo
require_command plutil
require_command shasum
require_command spctl
require_command xcodebuild
require_command xcrun

script_dir="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd
)"
repository_root="$(
    cd -- "${script_dir}/.."
    pwd
)"
output_dir="${OUTPUT_DIR:-${repository_root}/dist/release}"
release_work_dir="$(
    mktemp -d "${TMPDIR:-/tmp}/llamadock-release.XXXXXX"
)"
archive_path="${release_work_dir}/LlamaDock.xcarchive"
notary_archive="${release_work_dir}/LlamaDock-notary.zip"
notary_result="${release_work_dir}/notary-result.json"

cleanup() {
    if [[
        -n "${release_work_dir:-}"
        && -d "${release_work_dir}"
        && "${release_work_dir}" == *"/llamadock-release."*
    ]]; then
        rm -rf -- "${release_work_dir}"
    fi
}
trap cleanup EXIT

mkdir -p -- "${output_dir}"

cd -- "${repository_root}"
xcodebuild \
    -project Llamadock.xcodeproj \
    -scheme Llamadock \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${archive_path}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    ENABLE_HARDENED_RUNTIME=YES \
    archive

app_path="${archive_path}/Products/Applications/Llamadock.app"
info_plist="${app_path}/Contents/Info.plist"
executable_path="${app_path}/Contents/MacOS/Llamadock"
dsyms_path="${archive_path}/dSYMs"

[[ -d "${app_path}" ]] \
    || fail "archive did not contain Llamadock.app"
[[ -f "${info_plist}" ]] \
    || fail "archive did not contain an Info.plist"
[[ -f "${executable_path}" ]] \
    || fail "archive did not contain the app executable"

version="$(
    plutil -extract CFBundleShortVersionString raw \
        -o - "${info_plist}"
)"
build="$(
    plutil -extract CFBundleVersion raw \
        -o - "${info_plist}"
)"
expected_tag="v${version}"
release_tag="${RELEASE_TAG:-${expected_tag}}"
[[ "${release_tag}" == "${expected_tag}" ]] \
    || fail "tag ${release_tag} does not match app version ${version}"

architectures="$(lipo -archs "${executable_path}")"
[[ "${architectures}" == "arm64" ]] \
    || fail "release executable must be arm64-only; found: ${architectures}"

codesign --verify --deep --strict --verbose=2 "${app_path}"
signature_details="$(
    codesign --display --verbose=4 "${app_path}" 2>&1
)"
grep -Fq 'Authority=Developer ID Application:' \
    <<<"${signature_details}" \
    || fail "app is not signed with Developer ID Application"
grep -Eq 'flags=.*runtime' \
    <<<"${signature_details}" \
    || fail "Hardened Runtime is not enabled"

ditto -c -k --sequesterRsrc --keepParent \
    "${app_path}" "${notary_archive}"

notary_arguments=(
    submit
    "${notary_archive}"
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}"
    --wait
    --timeout 30m
    --output-format json
)
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    notary_arguments+=(--keychain "${NOTARY_KEYCHAIN}")
fi
xcrun notarytool "${notary_arguments[@]}" \
    >"${notary_result}"

notary_status="$(
    plutil -extract status raw -o - "${notary_result}"
)"
[[ "${notary_status}" == "Accepted" ]] \
    || fail "Apple notarization did not return Accepted"

xcrun stapler staple -v "${app_path}"
xcrun stapler validate -v "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
spctl --assess --type execute --verbose=4 "${app_path}"

archive_name="LlamaDock-${version}-macOS-arm64.zip"
dsym_name="LlamaDock-${version}-dSYM.zip"
archive_output="${output_dir}/${archive_name}"
dsym_output="${output_dir}/${dsym_name}"

[[ ! -e "${archive_output}" ]] \
    || fail "refusing to overwrite ${archive_output}"
[[ ! -e "${dsym_output}" ]] \
    || fail "refusing to overwrite ${dsym_output}"

ditto -c -k --sequesterRsrc --keepParent \
    "${app_path}" "${archive_output}"
[[ -d "${dsyms_path}" ]] \
    || fail "archive did not contain dSYMs"
ditto -c -k --sequesterRsrc --keepParent \
    "${dsyms_path}" "${dsym_output}"

(
    cd -- "${output_dir}"
    shasum -a 256 "${archive_name}" \
        >"${archive_name}.sha256"
    shasum -a 256 "${dsym_name}" \
        >"${dsym_name}.sha256"
    shasum -a 256 -c "${archive_name}.sha256"
    shasum -a 256 -c "${dsym_name}.sha256"
)

printf 'Release package ready: %s\n' "${archive_output}"
printf 'Version: %s (%s)\n' "${version}" "${build}"
printf 'Tag: %s\n' "${release_tag}"
printf 'Architecture: %s\n' "${architectures}"
printf 'Notarization: %s\n' "${notary_status}"
