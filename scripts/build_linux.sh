#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-aarch64}"
SWIFT_SDK_NAME="${SWIFT_SDK_NAME:-swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_static-linux-0.1.0}"

if command -v swiftly >/dev/null 2>&1 && [[ -f .swift-version ]]; then
  SWIFT=(swiftly run swift)
else
  SWIFT=(swift)
fi

SWIFT_SDK_PATH="$({
  "${SWIFT[@]}" sdk configure --show-configuration "${SWIFT_SDK_NAME}" |
    grep "sdkRootPath:" |
    head -1 |
    awk '{print $2}'
} || true)"

if [[ -z "${SWIFT_SDK_PATH}" ]]; then
  echo "Failed to resolve Swift SDK path for ${SWIFT_SDK_NAME}" >&2
  exit 1
fi

# The Swift Static Linux SDK's libc.a includes mimalloc. Linking a second copy
# causes duplicate allocator symbols, so use the SDK-provided static allocator.

"${SWIFT[@]}" build --build-system native -c release --product fltr --swift-sdk "${SWIFT_SDK_NAME}" --triple "${ARCH}-swift-linux-musl" \
  -Xlinker -z -Xlinker stack-size=0x80000
