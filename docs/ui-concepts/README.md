# Open Wisper visual directions

## Accepted direction: Swift island, Rust pill

Approved on November 3, 2026: **Swift uses the compact Bridge recording island; Rust uses an ordinary detached, fully rounded pill instead of Dynamic Island behavior.** Both open a **separate normal Pebble window** on explicit click, not one expanding surface. See [ADR-0001](../decisions/0001-native-ui-variants.md) for the accepted decision and [DESIGN.md](../../DESIGN.md) for the implementation target.

Open `bridge-pebble.html` and use its Swift/Rust selector to preview both variants. The palette pairs warm ivory with petrol ink, sea glass, and copper. The recording indicator is 248 px wide instead of the earlier 424 px Bridge (42% narrower); the independent Pebble window is 296 px wide. These are illustrative CSS dimensions, not hardware measurements. Both stay within the scene on narrow screens. The Rust pill has rounded ends on all sides and a visible gap from the top edge; it has no notch/camera integration. Switching variants changes only the mockup and preserves the current demo state.

The November 3 interaction refinement starts idle with **neither surface visible**. Activate demo (or Command+Shift+Space while the demo has focus) shows the selected recording indicator without opening Pebble. Clicking the indicator opens Pebble as an independent, nonmodal window with a title bar and close/minimize controls; the indicator stays compact. Closing the window does not stop recording. The illustrated menu-bar Wisper control can also open the window explicitly. The shortcut matches the native contract’s default but is not registered globally by this HTML study.

Stop moves the indicator to Processing; Finish sample previews the result. Stopping with Pebble closed previews insertion and briefly confirms it before hiding the indicator, without opening the window. If Pebble was open at Stop or completion, the demo offers Review/Copy instead of implying insertion into a previously focused editor. Review still requires an explicit click; a closed window never opens on completion. Settings and Copy are appearance-only. The window and indicator animate separately with a reduced-motion path, not a shared expansion. This is an accepted design reference, not an implementation: native Swift behavior is unchanged and the Rust app remains planned. Native focus behavior, permissions, and hardware safe areas are not validated by the demo.

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

Motion thesis: the only focal animation is the island silhouette changing with session state. Background editor content does not move or gain focus. The background shape uses a bounded transform animation; content has brief opacity feedback, and no waveform or audio-level simulation is shown. Native integration must preserve the nonactivating HUD contract, safe areas, display placement, and explicit review behavior. These concepts do not claim native Dynamic Island support or an already implemented Swift/Rust animation API. Bridge needs notch-aware placement; the other four do not require a notch.

Use the direction buttons to switch concepts. The first two galleries include Ready, Review, and Settings views plus matching compact recording indicators. The second round initially shows Carbon in Review to demonstrate its transcript-first composition; the third focuses on HUD states and shape changes rather than settings. In Compare/All five mode all five directions in that round appear together. Sample text, timer values, delivery messages, and configuration are illustrative; controls change only the local mockup. No audio is recorded and nothing is copied or inserted.

All concepts retain intentional recording, cursor insertion, explicit review/copy fallback, local processing, and no saved transcript history. A review window opens only on user request in the eventual implementation. The accepted Swift/Rust direction shares that interaction contract and Pebble layout but deliberately differs in recording-indicator shape; these files contain no native runtime coupling.

`DESIGN.md` now records the accepted variant-specific direction and links to ADR-0001; the native behavior contract is unchanged apart from a pointer to that visual decision. The Swift application and Electron baseline are unchanged. These studies target macOS desktop utilities, not a new website.

Before native implementation, translate the accepted direction into native fonts, point dimensions, real controls, keyboard focus, light/dark appearance, and Ready/Recording/Processing/Review/Error states. Any controls in these historical studies are illustrative rather than evidence of native capability; consult the app's actual status documentation for implemented model selection and other features.
