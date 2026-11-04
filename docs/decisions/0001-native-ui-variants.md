# ADR-0001: Swift island and Rust pill with a separate Pebble window

## Status

Accepted by the user on November 3, 2026. This is an approved design target, not a claim of native implementation or verification. The Rust application remains planned.

## Context

Three rounds of desktop UI studies explored fifteen alternatives, followed by a Bridge/Pebble refinement. The user approved that refinement with two constraints: the recording indicator must appear only after intentional activation, and clicking it must open Pebble as a normal, separate window rather than expand the indicator into the application. The final approval differentiates the two native variants: Dynamic Island–inspired Bridge for Swift only, a normal pill for Rust.

The applications share a behavior contract, not a runtime or a requirement for identical window chrome. Automatic cursor insertion, explicit Review/Copy fallback, and nonactivating recording feedback remain mandatory.

## Decision

### Swift: Bridge indicator

- Use the approved compact, top-edge, Dynamic Island–inspired Bridge recording indicator.
- Account for the display's actual notch/camera safe areas. The illustrative notch in the prototype is not a hardware specification or proof of native integration.
- Keep the indicator small while recording and processing; never morph it into the main app window.

### Rust: ordinary floating pill

- Use a detached pill-shaped recording indicator, fully rounded on every side.
- Do not attach it to the screen edge, build wings around a notch, reserve a simulated camera cutout, or implement Dynamic Island behavior.
- Keep a visible gap from the menu bar and apply normal display/work-area placement rules. The pill does not depend on a notched display.

### Shared Pebble window and workflow

- Retain Pebble's compact, centered layout, circular primary action, warm ivory surfaces, petrol teal controls, sea-glass secondary surfaces, and copper Stop/recovery accents.
- Start idle with neither recording indicator nor main window automatically visible. The menu-bar app remains available.
- Intentional shortcut activation shows only the relevant recording indicator without activating the app or stealing editor focus. The native contract's default is `Command+Shift+Space`.
- Clicking the indicator explicitly opens/focuses a separate, normal Pebble app window. This is not a modal, notch expansion, or attached popover. The indicator remains compact and recording continues.
- Closing or minimizing Pebble does not cancel dictation. The menu-bar action can also open the window explicitly.
- Stop moves to processing, then normal cursor delivery briefly confirms completion and dismisses the indicator. Completion never opens the main window automatically.
- If a safe insertion target cannot be established or revalidated, including when stopping with Wisper focused, offer explicit Review/Copy instead of guessing a previous editor or reactivating another app. A closed window stays closed until the user asks to open it.
- Keep settings and any current-session review in Pebble. Do not introduce saved transcript history.

The prototype's 248 px recording indicator and 296 px Pebble width are design proportions, not final native point dimensions. Native sizing must accommodate real settings/model controls, localized content, keyboard navigation, and supported display configurations. Use system typography and platform controls/accessibility behavior where appropriate. Respect Reduce Motion.

## Alternatives considered

- **Dynamic Island in both variants:** rejected because the user explicitly restricted that treatment to Swift.
- **Pill in both variants:** rejected because the user approved Bridge for Swift.
- **Expand the indicator into Pebble:** rejected because the user wants a normal window on explicit click, not one expanding surface.
- **Open Pebble on activation or completion:** rejected because it interrupts the dictation workflow and violates the focus/delivery contract.

## Consequences and boundaries

- Swift and Rust implement the same interaction contract with different recording-indicator silhouettes and placement. Neither native application requires the other application's runtime.
- The accepted reference is [the variant-aware prototype](../ui-concepts/bridge-pebble.html); [DESIGN.md](../../DESIGN.md) records the current target. The earlier galleries remain historical alternatives, not approved alternatives.
- This decision and its prototype do not modify Swift runtime behavior, create a Rust implementation, validate microphone or Accessibility permissions, or establish safe native focus behavior. Native implementation and conformance testing are separate work.
- The Electron MVP retains its separate existing UI.
