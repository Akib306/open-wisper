# Open Wisper

An open-source, local-first macOS dictation project. The existing Electron MVP is the reference baseline; independent Rust and Swift applications are planned, not implemented yet.

## Start here

- [Installed Wispr Flow investigation](docs/research/wispr-flow.md): artifact-backed findings, provenance, and remaining unknowns.
- [Rust and Swift implementation plan](docs/native-plan.md): architecture decisions, implementation tickets, and comparison gates.
- [Native v1 behavior contract](docs/native-contract.md): shared behavior and acceptance scenarios for both implementations.
- [Existing Electron MVP](mvp/README.md): setup and current functionality.
- [Historical MVP measurements](mvp/BENCHMARK.md): preliminary smoke measurements, not controlled native comparisons.

The native tracks share behavior specifications, test fixtures, and a reproducible speech-engine build. Neither application will require the other language's application core. No Wispr source, branding, service credentials, or private protocols are required to implement this plan.
