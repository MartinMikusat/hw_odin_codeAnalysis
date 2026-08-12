# Third-party notices

## OLS design reference

- Project: OLS
- Version: commit `ca8eb6da44c2b1c9e63736af05a5c3a5a298ea82`
- Source: <https://github.com/DanielGavin/ols>
- License: MIT
- License location: `research/reference-projects/ols/LICENSE` in the parent research workspace

OLS is read-only design reference material. It is not bundled with this project and is not a runtime dependency.

## Odin compiler packages

The project imports tokenizer, parser, and AST packages distributed with the Odin compiler.

- Version and checksum: the active official monthly release recorded by `hw-odin toolchain status --json`
- Source: <https://github.com/odin-lang/Odin/releases>
- License: BSD 3-Clause
- License location: the `LICENSE` file in the installed Odin distribution

The compiler distribution is not bundled with this project. The installed
analyzer resolves and reads its active `base/builtin/builtin.odin` source through `hw-odin toolchain root` at runtime.
