# Third-party notices

Release archives include this file, `LICENSE`, and the `LICENSES` directory.
The files in that directory contain the complete license texts named below.

## Apache-2.0

The following SwiftPM dependencies are distributed under Apache License 2.0.
Their license text is in `LICENSES/Apache-2.0.txt`.

- FuzzyMatch 1.4.0 — <https://github.com/ordo-one/FuzzyMatch>
- swift-argument-parser 1.8.2 — <https://github.com/apple/swift-argument-parser>
- swift-async-algorithms (transitive dependency) — <https://github.com/apple/swift-async-algorithms>
- swift-collections 1.6.0 — <https://github.com/apple/swift-collections>
- swift-subprocess 1.0.0-beta.1 — <https://github.com/swiftlang/swift-subprocess>
- swift-system 1.7.5 — <https://github.com/apple/swift-system>
- Swift 6.4 runtime libraries in the static Linux binary — Apache-2.0 with
  the Runtime Library Exception in `LICENSES/Swift-Runtime-Exception.txt`

None of the resolved package distributions above includes a `NOTICE` file.

## MIT

- swift-displaywidth 0.1.0 — `LICENSES/swift-displaywidth-MIT.txt`
- mimalloc, included by the Swift Static Linux SDK — `LICENSES/mimalloc-MIT.txt`
- musl 1.2.5, linked into the static Linux binary — `LICENSES/musl-COPYRIGHT.txt`

The GitHub Release also includes the Swift Static Linux SDK's SPDX inventory as
`fltr-sbom-static-linux-sdk.spdx.json`. The static binary audit found that the
two release architectures link musl and mimalloc, but not the SDK's curl,
BoringSSL, libarchive, libxml2, or compression libraries.
