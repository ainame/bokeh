#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-directory>" >&2
  exit 64
fi

output_dir="$1"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

mkdir -p "$output_dir"

swift package --disable-automatic-resolution generate-sbom \
  --product fltr \
  --sbom-spec cyclonedx \
  --sbom-spec spdx \
  --sbom-output-dir "$temporary_dir"

cyclonedx_sbom=("$temporary_dir"/cyclonedx*.json)
spdx_sbom=("$temporary_dir"/spdx*.json)

if [[ ${#cyclonedx_sbom[@]} -ne 1 || ${#spdx_sbom[@]} -ne 1 ]]; then
  echo "expected one CycloneDX and one SPDX SBOM" >&2
  exit 1
fi

cp "${cyclonedx_sbom[0]}" "$output_dir/fltr-sbom-cyclonedx.json"
cp "${spdx_sbom[0]}" "$output_dir/fltr-sbom-spdx.json"
