# Third-party notices

Teleport is licensed under GPL-3.0-or-later (see `LICENSE`). It ships the
following third-party components. The project has no Swift package
dependencies; everything else it links is part of the macOS SDK.

## Xray-core

- Files: `teleport/Resources/xray`
- Version: 26.6.27 (`xray version` reports `Xray 26.6.27 ... 45cf289 (go1.26.4 darwin/arm64)`)
- Source: https://github.com/XTLS/Xray-core, tag `v26.6.27`
- License: Mozilla Public License 2.0, https://github.com/XTLS/Xray-core/blob/main/LICENSE

The bundled executable is byte for byte the `xray` file from the official
release asset `Xray-macos-arm64-v8a.zip` of that tag (SHA-256
`650e6edf792ce808554e94f891db5271c77a7c2e80188beaafbf24883b3b84a0`, the same
value `BundledArtifactPolicy.swift` pins). `scripts/fetch-xray.sh` downloads
that asset again, checks it against the digest XTLS publishes and against the
pin, and places the executable in `teleport/Resources/`.

Xray-core is unmodified. Its source is available at the link above; the MPL
applies to the Xray files only and does not change the license of Teleport's
own code.

## Routing data: geoip.dat and geosite.dat

- Files: `teleport/Resources/xray-assets/geoip.dat`,
  `teleport/Resources/xray-assets/geosite.dat`
- SHA-256: `744c97b74c52bae2ac8664fef6ac481d7765cb8432a0df54f0368a88b9b4a354`
  (geoip.dat), `c202e5ed36a591ddd6d7b0164453d36c7c91a32be45e4d26256fd19d24c70b71`
  (geosite.dat)

These two files were copied in July 2026 together with an Xray installation and
the exact upstream release was not recorded. They do not match the files in the
`v26.6.27` release asset. The data they contain comes from one of the projects
below, which are the ones that publish these file formats; the licenses listed
are the ones those projects state.

- XTLS/Xray-rules-dat, https://github.com/XTLS/Xray-rules-dat, GPL-3.0. This
  is what the official Xray release zips bundle. Its geoip data is based on
  IPinfo Lite; its geosite data is taken from v2fly/domain-list-community.
- v2fly/geoip, https://github.com/v2fly/geoip, CC-BY-SA-4.0.
- v2fly/domain-list-community, https://github.com/v2fly/domain-list-community,
  MIT. Its release file `dlc.dat` is the usual `geosite.dat`.

The Geodata settings page can replace both files with downloads from a source of
the user's choice; the bundled copies are only the defaults.
