#!/usr/bin/env bash
set -euo pipefail

MIMALLOC_VERSION="${MIMALLOC_VERSION:-3.0.10}"
ARCH="${ARCH:-aarch64}"

SWIFT_SDK_PATH="$({
  swift sdk configure --show-configuration swift-6.2.3-RELEASE_static-linux-0.0.1 |
    grep "sdkRootPath:" |
    head -1 |
    awk '{print $2}'
} || true)"

if [[ -z "${SWIFT_SDK_PATH}" ]]; then
  echo "Failed to resolve Swift SDK path for swift-6.2.3-RELEASE_static-linux-0.0.1" >&2
  exit 1
fi

if [[ ! -f "mimalloc-build-${ARCH}/libmimalloc.a" ]]; then
  echo "Building mimalloc ${MIMALLOC_VERSION} for ${ARCH}..."
  if [[ ! -d "mimalloc-${MIMALLOC_VERSION}" ]]; then
    curl -sSfL "https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}.tar.gz" | tar xz
  fi

  mkdir -p "mimalloc-build-${ARCH}"
  clang --target="${ARCH}-unknown-linux-musl" \
    --sysroot="${SWIFT_SDK_PATH}" \
    -O3 -DNDEBUG -DMI_LIBC_MUSL=1 -DMI_STATIC_LIB \
    -fvisibility=hidden -fno-builtin-malloc \
    -I"mimalloc-${MIMALLOC_VERSION}/include" \
    -c "mimalloc-${MIMALLOC_VERSION}/src/alloc.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/alloc-aligned.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/alloc-posix.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/arena.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/arena-meta.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/bitmap.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/heap.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/init.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/libc.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/options.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/os.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/page.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/page-map.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/random.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/stats.c" \
      "mimalloc-${MIMALLOC_VERSION}/src/prim/prim.c"
  ar rcs "mimalloc-build-${ARCH}/libmimalloc.a" *.o
  rm -f ./*.o
fi

swift build -c release --product fltr --swift-sdk "${ARCH}-swift-linux-musl" \
  -Xlinker -z -Xlinker stack-size=0x80000 \
  -Xlinker --whole-archive \
  -Xlinker "./mimalloc-build-${ARCH}/libmimalloc.a" \
  -Xlinker --no-whole-archive
