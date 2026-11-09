# Third-party notices

Teleport is licensed under GPL-3.0-or-later (see `LICENSE`). It ships the
following third-party components. The project has no Swift package
dependencies; everything else it links is part of the macOS SDK.

## Xray-core

- Files: `teleport/Resources/xray`
- Version: 26.11.9 (`xray version` reports `Xray 26.11.9 ... 676eaf6 (go1.27.3 darwin/arm64)` or `darwin/amd64`, depending on the slice that runs)
- Source: https://github.com/XTLS/Xray-core, tag `v26.11.9`
- License: Mozilla Public License 2.0, https://github.com/XTLS/Xray-core/blob/main/LICENSE

The bundled executable is a universal binary (SHA-256
`42d74053687fd3fa64d5eca560709aceda7c96297f10a1424aece8aa83ec192f`, the same
value `BundledArtifactPolicy.swift` pins) made with `lipo -create` from the
`xray` files of two official release assets of that tag:

- `Xray-macos-arm64-v8a.zip`, arm64 slice, SHA-256
  `1b2d5ebe3a4c332203db24b81a052c6d6688a7f80705090f031b7416013ee1b2`
- `Xray-macos-64.zip`, x86_64 slice, SHA-256
  `e0421c5877c4819f672b5bc56e553502a4e14efcc17ec88691240a5d7f52cc31`

`lipo -thin <arch>` recovers each upstream file byte for byte.
`scripts/fetch-xray.sh` downloads both assets again, checks each against the
digest XTLS publishes, joins them, checks the result against the pin, and
places the executable in `teleport/Resources/`.

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
