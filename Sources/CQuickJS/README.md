# CQuickJS

This SwiftPM C target vendors the minimal embeddable engine from
[quickjs-ng](https://github.com/quickjs-ng/quickjs) release `v0.16.2` (August 20, 2026). The source archive is
`https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.16.2.tar.gz` with SHA-256
`97c80625b26775a4c7ca618c004d4ea24cf99cbf867e4eba78bd927a8b23d106`.

The target retains the four upstream engine translation units, 14 required headers, and the upstream MIT license: 19
vendored files totaling 2,822,586 bytes. It intentionally excludes the `qjs`/`qjsc` CLIs, REPL, libc modules, examples,
tests, and build-system files. The sources are unmodified; SwiftPM compile definitions and linker settings live in
`Package.swift`.

Run `Scripts/regenerate-quickjs-vendor.sh check` to verify the checked-in files or
`Scripts/regenerate-quickjs-vendor.sh write` to download, checksum, and re-stage them.
