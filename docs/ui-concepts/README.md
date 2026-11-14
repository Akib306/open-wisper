# Open Wisper visual directions

## Current decision and historical study

[ADR-0002](../decisions/0002-bottom-pill.md) selects a bottom pill for both native variants and a separate Pebble window. [DESIGN.md](../../DESIGN.md) records the current target, implemented in Swift source. Rust remains planned; see [Swift status](../swift-status.md) for verification and remaining live checks.

[Bridge and Pebble](bridge-pebble.html) is a historical November 3 study: its Swift island and Rust top pill placement were superseded. Its separate window and interaction ideas remain context, not proof of native focus, permission, or delivery behavior. The mockup uses illustrative dimensions and demo states; it records no audio and does not insert or copy text.

## Historical explorations

Fifteen unapproved, presentation-only desktop concepts for a shared Swift/Rust visual language. Open `index.html` for the original five, `round-two.html` for the second round, or `dynamic-islands.html` for the five Dynamic Island–inspired concepts. None needs a server, account, installation, or application permissions.

| Direction | Composition | Character |
| --- | --- | --- |
| Quiet | Compact native utility, vertically stacked | Familiar, restrained, blue and porcelain |
| Folio | Two-column editorial workspace | Warm paper, ink, serif typography |
| Signal | Dark recording console | High contrast, industrial, tactile yellow controls |
| Pebble | Small menu-bar popover, centered action | Soft plum, rounded silhouette, friendly |
| Rail | Horizontal utility with a narrow navigation rail | Crisp graphite, lime accent, information-dense |

## Second round

| Direction | Composition | Character |
| --- | --- | --- |
| Command | Keyboard-first action launcher | Compact command list, cool monochrome |
| Index | Asymmetric text and full-height action plane | Swiss typography, vermilion, square geometry |
| Ribbon | Floating toolbar with on-demand drawers | Minimal footprint, soft green-white, no main window |
| Carbon | Full-width current-transcript canvas | Warm charcoal, large text, edge-positioned controls |
| Classic | One-bit retro Mac control panel | Black rules, square window, color-independent controls |

## Dynamic Island round

| Direction | Placement | Expansion model |
| --- | --- | --- |
| Pulse | Detached, top-center capsule | Soft compact-to-expanded review surface |
| Bridge | Attached to the top edge around an illustrated notch | Horizontal wings, downward review, reserved camera keep-out |
| Duet | Top-center capsule with a separate circular action | Status and primary action occupy independent islands |
| Lift | Bottom-center floating dock | Transcript expands upward above the anchored transport row |
| Tuck | Upper-right corner | Narrow, asymmetric downward review panel |

The third gallery previews Ready, Recording, Processing, Inserted, and Review across all five islands. Its Play cycle control runs one bounded demonstration and returns to Ready; it does not loop. Stop changes only the selected mockup to Processing. Review is explicit, and Copy never accesses the clipboard. A reduced-motion preference removes spatial morphing while retaining short opacity feedback. The third-round scenes show an illustrative desktop editor, not an actual app capture or an iPhone UI.

Motion thesis: the only focal animation is the island silhouette changing with session state. Background editor content does not move or gain focus. The background shape uses a bounded transform animation; content has brief opacity feedback, and no waveform or audio-level simulation is shown. The current native contract preserves nonactivation and explicit review; these historical placement concepts are superseded. These concepts do not claim native Dynamic Island support or an already implemented Swift/Rust animation API. Bridge needs notch-aware placement; the other four do not require a notch.

Use the direction buttons to switch concepts. The first two galleries include Ready, Review, and Settings views plus matching compact recording indicators. The second round initially shows Carbon in Review to demonstrate its transcript-first composition; the third focuses on HUD states and shape changes rather than settings. In Compare/All five mode all five directions in that round appear together. Sample text, timer values, delivery messages, and configuration are illustrative; controls change only the local mockup. No audio is recorded and nothing is copied or inserted.

These historical concepts explore intentional recording, cursor insertion, explicit review/copy fallback, local processing, and no saved transcript history. Controls and dimensions are illustrative; consult the current decision and Swift status for implementation and verification.
