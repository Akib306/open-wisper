# Approved native UI direction

Accepted November 14, 2026 for native Swift and the planned independent Rust application. The Electron MVP retains its separate UI. [ADR-0002](docs/decisions/0002-bottom-pill.md) supersedes the shape and placement decision in ADR-0001. Swift implements the bottom pill; Rust remains planned. See [Swift verification status](docs/swift-status.md) for evidence and limitations.

## Recording indicator

Both native variants use one nonactivating, solid petrol Capsule at the bottom of the display in every visible state. Center and bound it within the usable work area, with its bottom at `visibleFrame.minY + 28` pt, above the Dock. Do not integrate with a notch or attach to the menu bar. The indicator renders the coordinator's current state and never owns capture. First-click Stop/Cancel must not activate the app; explicit status opens Pebble, Review selects transcript review, and setup opens Settings. Success and cancellation receive brief feedback; fallback review persists until user action. Display placement and focus conformance require native verification.

Pebble defaults to 360 × 480 pt with a 340 × 420 pt minimum; settings and long content scroll. The [earlier interactive study](docs/ui-concepts/bridge-pebble.html) is historical, not a placement reference.

## Separate Pebble main window

- Use Pebble's compact centered layout and circular primary action in a normal app window with a title bar and native close/minimize behavior. It is not a modal, an attached popover, or an expanded indicator.
- Follow the reference's single-line microphone/wordmark, text-only segmented navigation, two-line Ready heading, and action label inside the circular button. Review is its own surface, not a transcript appended below Ready. Settings uses unboxed, separated groups with advanced engine details disclosed on demand.
- Clicking the recording indicator explicitly opens/focuses this window; the recording indicator remains compact. A menu-bar action can also open it.
- Closing or minimizing the window does not stop recording. Activation and successful completion never open it automatically.
- The mockup's 296 px window width is a starting proportion. Native sizing must accommodate real model selection, engine controls/status, readable transcript text, localization, and scrollable settings; do not remove capabilities to fit the sketch.
- Keep Ready, current-session Review, and Settings readily accessible. Use system typography, SF Symbols or equivalent consistent native icons, semantic control states, selectable text, and native keyboard behavior. No saved transcript history by default.

## Palette and typography

| Role | Reference color |
| --- | --- |
| Warm ivory window surface | `#fff8ee` |
| Petrol ink / indicator | `#213f40` |
| Teal primary action | `#285b59` |
| Sea-glass secondary surface | `#d9e8df` |
| Supporting text on ivory | `#596b65` |
| Copper Stop/recovery accent | `#9b4a30` on `#f6e3d3` |

Color never carries state alone: pair it with phase text, recognizable controls, and accessible names. Use system fonts with a clear hierarchy, comfortable text spacing, and tabular timer digits. Preserve macOS appearance support and verify contrast in both appearances; the HTML palette is a reference, not a claim that native dark-mode tokens have been finished. Respect Reduce Motion; reveal the indicator and the separate window independently, without a shared expansion or decorative audio simulation.

## Interaction and safety

1. Idle: neither recording indicator nor main window opens automatically; the menu-bar app stays available.
2. Intentional activation (`Command+Shift+Space` by default): start recording and show only the nonactivating pill. Keep the editor focused.
3. Explicit indicator click: open/focus the separate Pebble window; recording continues. This user action may activate the app, unlike automatic HUD updates.
4. Stop: process and attempt cursor insertion only within the existing [native behavior contract](docs/native-contract.md). If stopping with Wisper focused, or if the target cannot be established/revalidated, offer Review/Copy rather than guessing a previous app or moving focus for delivery.
5. Completion: briefly confirm success or cancellation and dismiss the indicator; never open a closed window automatically. Recovery opens Pebble only after an explicit action.

Retain feature-scoped microphone and Accessibility setup, clear insertion-permission recovery, disclosure of temporary clipboard use, the real Edit menu, and accessible labels on icon-only controls. Empty, recording, processing, cancelled, error/recovery, and completed states must remain explicit. Do not introduce dense diagnostics, gradients, custom display fonts, or simulated audio levels. Existing local model provisioning and selection remain functional requirements rather than decorative prototype settings.

HTML studies establish visual intent only. Real focus behavior, permission flows, supported safe areas, appearance variants, and native delivery require the implementation and manual checks tracked in [Swift verification status](docs/swift-status.md) and the native behavior contract.
