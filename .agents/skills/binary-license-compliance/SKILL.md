---
name: binary-license-compliance
description: Audit and improve open-source license notices for distributed binary releases, including SwiftPM SBOMs, static SDK/runtime dependencies, release archives, and GitHub Release workflows. Use when Codex is asked whether a binary distribution is license-compliant, to add third-party notices, to assess whether an SBOM is sufficient, or to package license materials with CLI, desktop, mobile, or static-Linux artifacts.
---

# Binary license compliance

Treat this as an engineering compliance audit, not legal advice. Do not claim
complete compliance without an inventory of every component that the shipped
artifact incorporates and a review of its license obligations.

## Audit

1. Identify every distribution channel and artifact: source, archive, installer,
   container, app store bundle, static binary, and release attachment.
2. Read manifests and lockfiles, then generate or inspect an SBOM. Treat the
   SBOM as inventory evidence, not as a replacement for license notices.
3. Inspect every resolved dependency's license and `NOTICE` file. Record direct
   and transitive dependencies, resolved version/revision, source URL, and
   license identifier.
4. For static or cross-compiled artifacts, inspect the SDK/toolchain separately.
   SwiftPM SBOMs normally omit static SDK libraries. For Swift static SDKs:

   ```bash
   swift sdk configure --show-configuration <sdk-name>
   # Locate the artifact bundle's sbom.spdx.json, then inspect package licenses:
   jq -r '.packages[] | [.name, .versionInfo, .licenseConcluded] | @tsv' sbom.spdx.json
   ```

5. Inspect the built archive itself. Verify its file list and, for static
   binaries, verify the claimed linkage and allocator/runtime evidence.

Use authoritative upstream license files or official license publishers when
the local checkout is incomplete. Browse by default for legal accuracy.

## Apply notices

Prefer one readable `THIRD_PARTY_NOTICES.md` plus a `LICENSES/` directory in
every distributable archive. Include the project's own `LICENSE` too.

- Copy the complete text of each required license and copyright notice.
- Include every upstream `NOTICE` file when present.
- A URL-only attribution or an SBOM is not a reliable substitute for a license
  notice. An app's legal screen can be a delivery location only when it carries
  the required text and is accessible to recipients.
- Deduplicate shared license text only when the per-component attribution makes
  clear which components use it. Do not require one file per dependency.
- Keep platform-specific notices in the shared bundle when practical; list
  platform-only components explicitly.

For Apache-2.0, provide its license text and preserve required NOTICE content.
For MIT, include the copyright and permission notice. Check any additional
exceptions, copyleft terms, and attribution clauses from the actual dependency;
do not generalize from an SPDX identifier alone.

## Automate distribution

Update the release packaging workflow so every archive contains the same notice
bundle. Keep SBOMs as separate release attachments unless users explicitly
need self-contained offline compliance material. If an SDK publishes its own
SBOM, consider attaching it separately and use it to drive the SDK audit.

Update user-facing installation/release documentation to describe the notice
bundle. Avoid hard-coded one-off license filenames when a combined notices
bundle is the intended interface.

## Validate and report

Before finishing:

1. Parse workflow/configuration files and review the final diff.
2. Build or stage representative archives, then list ZIP/tar contents to prove
   `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `LICENSES/` are present.
3. Verify copied license text against the authoritative checkout where possible.
4. State the exact covered scope and any remaining unaudited SDK, system, or
   app-store component boundary. Do not describe partial coverage as complete.
5. Commit focused repository changes, but do not push, tag, or republish a
   release unless the user requests it.
