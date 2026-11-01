# Native Swift utility

Scope: `native/swift`. The user selected a compact native menu-bar utility. The Electron MVP retains its existing separate interface.

Use macOS semantic colors, system typography, SF Symbols, standard buttons and grouped forms. Follow the user's system appearance. The title uses `title3/semibold`, the current task uses `title2/semibold`, transcript text uses `body` with 5 pt line spacing, supporting text uses `callout`/`caption`. The default window content is 500 × 590 pt; content stays usable at a 460 × 540 pt window and settings scrolls. Main spacing is 22 pt padding, 18 pt between content groups, and 7–12 pt within groups.

The primary action is Start/Stop from the current editor. Cursor insertion is the default outcome, and completion must not activate the review window. An insertion that cannot proceed offers Review/Copy in the nonactivating indicator; only Review opens the window. Show a clear Accessibility setup action when insertion is enabled but unavailable. Settings is a secondary gear control. Use the system accent for primary actions and red only for active recording/Stop; every state also has a text label. Transcript/recovery surfaces use 8 pt corners and native text/control backgrounds. Avoid decorative motion, gradients, custom fonts, dense diagnostics, and simulated audio levels.

The recording indicator is a 340 × 64 pt nonactivating panel, with 16 pt horizontal/12 pt vertical padding and a 14 pt native-material outline. Material is functional floating-window treatment. It names the phase and offers Stop/Cancel without changing the target application's activation. It never owns capture.

Keep accessibility labels on icon-only controls, native keyboard focus, selectable transcript text, a real Edit menu, and clear disclosure of temporary clipboard use in Settings. Empty, processing, cancelled, error, and completed states must remain explicit. Layout captures only verify visual structure; live focus and permission behavior require the manual suite in `docs/swift-status.md`.
