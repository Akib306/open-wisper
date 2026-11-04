# Open Wisper

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS (Swift/AppKit/SwiftUI), initially Apple Silicon; the existing Electron app remains a separate baseline.

## Users and purpose

People dictating into their Mac's existing applications. The primary task is to place the cursor in a text field, start from a shortcut, speak, and stop to insert the local transcript without switching windows.

## Capabilities and constraints

The user selected a compact native menu-bar utility on October 30, 2026 and clarified on October 31 that automatic cursor insertion is essential. Implement the baseline in `docs/native-contract.md`, with a separate Swift application and no Rust or Electron runtime dependency. Use an explicitly provisioned local whisper.cpp engine. Enable insertion by default, with one explicit Accessibility setup flow. Support direct Accessibility replacement and a guarded clipboard-paste fallback. Fail closed when the target cannot be established, and offer a nonactivating Review/Copy indicator. Never submit text, activate another application for delivery, or persist transcript history by default.

## Evidence on hand

The user approved the visual direction on November 3, 2026: a Dynamic Island–inspired Bridge recording indicator for Swift only, a normal floating pill indicator for the planned Rust app, and a separate Pebble main window opened by explicit click in both. Activation shows the indicator without opening the app; completion must not open the app automatically. [ADR-0001](docs/decisions/0001-native-ui-variants.md) and [DESIGN.md](DESIGN.md) record the target. The HTML reference is a UI study, not implemented or verified native behavior.

`docs/research/wispr-flow.md` is a bounded static investigation, not proof of runtime parity. `docs/native-plan.md` sets the architecture. The Electron source is an implementation reference; no original proprietary source or assets belong in the native application.

## Product principles

- Recording must be intentional and visible without taking focus.
- Stopping dictation inserts at the cursor; completion never opens the app automatically.
- Review and explicit Copy are the reliable fallback.
- Local dictation requires no account or recurring authentication.
- Errors preserve user control and describe a recovery action.

## Open decisions

Public distribution signing, project license, multilingual profiles, rewriting, history, and full release conformance remain separate decisions.
