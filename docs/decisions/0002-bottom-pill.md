# ADR-0002: Bottom pill and separate Pebble window

## Status

Accepted by the user on November 14, 2026. This supersedes [ADR-0001](0001-native-ui-variants.md) only for indicator shape and placement; its separate-window and shared workflow decisions remain, as clarified below. This is a design target, not evidence of completed implementation or verification. Rust remains planned.

## Context

The earlier Swift Bridge integrated with the notch while Rust used a detached top pill. The user reports that insertion often falls back to Copy and the island status can be out of sync. Delivery diagnosis continues; the visual decision does not establish a delivery repair. A common, simple placement avoids making the recording interface depend on a notch.

## Decision

- Swift and planned Rust use a single solid petrol Capsule in every visible state, centered and bounded in the display's usable work area, with its bottom at `visibleFrame.minY + 28` pt above the Dock. No notch or menu-bar integration.
- The coordinator owns session state; all indicator status derives from it. The indicator does not own capture. Stop and Cancel accept the first click without activating the app.
- Idle launch hides the indicator and window. Explicit status opens the separate Pebble window; Review selects transcript review and setup opens Settings. Pebble defaults to 360 × 480 pt, minimum 340 × 420 pt, with scrolling content. Closing or minimizing it does not cancel capture.
- Success and cancellation receive brief feedback; fallback review persists until user action. Completion does not automatically open the window.
- Automatic insertion remains the default, preserving an explicit opt-out and all permission, target, focus, and delivery guards. Unsafe or unavailable delivery offers Review/Copy; it must not guess a target or retry an ambiguous insertion.

## Alternatives considered

- **Swift Bridge and Rust top pill:** superseded by the shared bottom pill; neither notch integration nor top placement is the current target.
- **Expand the indicator into the app:** rejected; Settings and Review remain in an independent normal window.

## Consequences and boundaries

The [earlier prototype](../ui-concepts/bridge-pebble.html) and island studies are historical. Swift source implements this decision; [Swift status](../swift-status.md) records verification and remaining native display, focus, and delivery checks. Changing source does not update an installed app. No account login is needed; macOS may request Touch ID or a password during Accessibility changes, and ad-hoc code identity changes can require renewed permission. Existing safety and privacy requirements in the [native contract](../native-contract.md) remain in force.
