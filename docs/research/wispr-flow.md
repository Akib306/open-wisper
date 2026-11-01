# Installed Wispr Flow: bounded static investigation

Investigation date: **October 30, 2026, America/Regina**. Target: the installed **Wispr Flow 1.6.1264**, not a claim about the newest published version.

## Scope and method

REA 6.8.0 inventoried the installed ASAR, extracted it into an analysis temporary directory, and parsed selected JavaScript sources as inert text. Additional read-only inspections examined the outer bundle plist, selected extracted source regions, packaged migrations, and a nested native helper. No proprietary application code was executed for this investigation, and no microphone recording, login, service request, user database, Keychain, transcript history, or live network traffic was inspected.

The initial native procedure search failed at macOS Automation authorization; read-only Mach-O inspection succeeded independently. The November 1 follow-up below records the later successful search and supplemental Hopper-native analysis. The original architecture findings are not retroactively upgraded to runtime observations.

This is a **partial static architecture investigation**, sufficient to choose an implementation direction, not a complete reverse engineering or demonstrated behavioral equivalence. Filenames, dependency declarations, imports, and feature strings do not prove runtime use, current rollout, or entitlement availability.

## Artifact identity

| Artifact | Identity |
| --- | --- |
| Installed application | `/Applications/Wispr Flow.app` |
| Outer bundle identifier | `com.electron.wispr-flow` |
| Outer version/build | `1.6.1264` / `1.6.1264` |
| Application archive | `Contents/Resources/app.asar` |
| ASAR SHA-256 | `e43cc5c91c0870bacfd3cddc4e5dbefdbd54399f1e8d20fda485e46107bd2c57` |
| Nested helper | `Contents/Resources/swift-helper-app-dist/Wispr Flow.app` |
| Helper bundle identifier | `com.electron.wispr-flow.accessibility-mac-app` |
| Helper executable architecture | `arm64` |
| Helper executable SHA-256 | `78d232a48a80e6c823339ee5a683b8674f23e7e73d2c9fa8d123b49f455b2e10` |

The outer plist's `ElectronAsarIntegrity` declaration is not treated as the full-file SHA-256 reported above. These values were not established to cover the same byte domain.

## Finding ledger

**Observed-static** means the stated artifact content was inspected. **Inferred** means a proposed architectural interpretation. Neither means execution was observed.

| ID | Finding and evidence | Classification / implementation consequence |
| --- | --- | --- |
| F01 | Packaged `package.json` declares `.webpack/main` as entrypoint, React, Electron-related libraries, Zustand, Sequelize, and SQLite dependencies. Renderer entrypoints include `hub`, `overlay`, `status`, `scratchpad`, and `meeting_recorder`. E1/E2/E3, S1. | Observed-static packaging; a multi-window Electron client is strongly supported. Do not reproduce its shell simply to reproduce dictation. |
| F02 | The nested helper has `LSUIElement=true`, the accessibility-specific bundle identifier above, and Swift runtime symbols in its Mach-O import inventory. E5/E6. | Observed-static. The product already crosses a native boundary; “all TypeScript” is an inaccurate architectural description. |
| F03 | Main-bundle exports include native helper adapters for text-box inspection, selected-text copying, paste-and-helper-relaunch, and helper transport. The helper imports AXUIElement and CGEvent APIs. S2, E5/S6. | Observed-static interfaces/imports; actual insertion strategy and reliability remain unknown. Treat text delivery as a first-class platform subsystem. |
| F04 | `recorderWorklet.js` registers an AudioWorklet processor, accepts start/stop messages, batches Float32 samples in 640-sample buffers, and flushes remaining samples before a completion message. E3/S3. | Observed-static source behavior. The sample rate is not established by this file, so 640 samples must not be called a fixed millisecond interval. Use a nonblocking capture pipeline in both native tracks. |
| F05 | Main-bundle request methods construct ASR requests to `/llm/asr` and `/llm/asr_audio_chunks`; another request path targets `/llm/dictation`. Service configuration contains remote HTTPS/WSS origins. S2. | Observed-static network-capable paths; which path a live session uses, model identity, audio residency, and server-side transforms are unknown. A local engine is our deliberate design choice, not a recovered Wispr engine. |
| F06 | Start-dictation logic explicitly checks stopping and initializing states and contains active-session cleanup handling. S2. | Observed-static control-flow region. Session races deserve a serialized coordinator, not UI-owned booleans. Full transition coverage was not recovered. |
| F07 | Packaged history migrations declare raw, formatted, edited, and pasted text, audio, screenshot, app/URL/context, accessibility text, and formatting-divergence fields. S4. | Observed-static schema intent; not proof that those fields are populated or uploaded. Separate raw text, processed text, delivery, and retention policies in our design. Do not copy these schemas. |
| F08 | A packaged Polish migration declares initial/polished text, instructions, processing time, status variants, undo, and an upload flag. Main code exposes `polish:runPolish`. S4/S2. | Observed-static feature/schema surfaces. Exact prompts, algorithms, quality, and enabled behavior are unknown. Make rewriting optional and independent of ASR. |
| F09 | Main code includes dictionary, snippet, personalized-style, and formatting feature markers. Packaged migrations and renderer names also expose meeting/notes-related surfaces. S2/S5. | Feature candidates, not verified user-visible functionality. Prioritize dictation; defer the adjacent product suite. |
| F10 | The hub preload exposes a contextBridge API including clipboard operations, IPC, platform information, and restricted external-link handling. E3/S7. | Observed-static bridge surface. Native apps need no renderer bridge; keep platform capabilities behind narrow internal interfaces. |

### Architectural interpretation

```text
Electron UI and application orchestration
    ├── capture/worklet and encoding-related workers
    ├── native helper adapter → macOS accessibility/input integration
    ├── network-capable ASR/dictation/formatting paths
    └── local data models and migrations
```

This is a source-supported decomposition, **not a captured runtime call graph**. The most useful reconstruction target is the workflow: invoke without losing focus, capture speech, transcribe, optionally transform, and safely deliver text. Rebuilding the whole Electron client or matching its backend is unnecessary for that target.

## Integrity and coverage limitations

REA reported three companion-file hash contradictions against ASAR declarations:

- `.webpack/main/native_modules/build/Release/node_sqlite3.node`
- `.webpack/main/native_modules/jabra-device-connector/darwin/jabra-device-connector`
- `.webpack/main/native_modules/panel_activation.node`

Inspection/extraction continued with explicit `record-and-continue`. These bytes remain **observed-untrusted**. Post-packaging signing/stripping is a possible explanation, not an established explanation or an authenticity verdict. No equivalence claim relies on them. The nested helper is a separate artifact and is not one of these three entries; its authenticity was not verified either.

The inventory reported 793 files and 170 directories. Initial source selection included the 10,131,326-byte main bundle, but its semantic analysis hit a 120,000 ms provider deadline. The partial result was retained, not mistaken for successful main-code analysis. A subsequent bounded selection of the manifest, hub preload, and recorder worklet completed with semantic retention limits; 180 inventoried files remained outside that selection. Targeted manual reading of the extracted main bundle supports only the specific regions in this report.

Hopper returned: `Not authorized to send Apple events to Hopper Disassembler.` Enabling Automation for the app that launches REA is an optional follow-up, not a prerequisite for implementing either native track. No permissions or analysis-tool installations were changed to get around this boundary.

## Evidence index

### REA evidence

| Alias | Evidence ID | Coverage |
| --- | --- | --- |
| E1 | `ev_ca8b5e9b9e9e7151c318d5420a7774d83aeabad0887a054853e82b56b21cae78` | Complete ASAR member inventory within reader scope; three integrity contradictions. |
| E2 | `ev_89fc702738a436ff92566876d10ad4cded8f7b6ff5729b9bdb51d9ed4a19a502` | Extracted regular-file identities; contradictions preserved. |
| E3 | `ev_2e89bd9ced5aff5e3e748b314068e5f97726b7c46799ed24216da229ca9b575b` | Selected manifest/preload/worklet analysis; bounded, partial application/semantic coverage. |
| E4 | `ev_cd34220becb5028a65b7277adb08a0a436dd47a42479ccc672f7611f1c0168f8` | Interrupted main-bundle analysis; not authority for a recovered main graph. |
| E5 | `ev_12b2ab3f8582686adfc5fb77ef2376fc9622cdffc3b6d0915b29d82997c37a12` | Helper Mach-O metadata/imports; import/export enumeration is not exhaustive. |
| E6 | `ev_53e01b59dd39577722e2e013c08b9d86a2f0b62f61aab93ae6c149a28c500f86` | Helper plist. |

Raw evidence exports are local-only at `/private/tmp/open-wisper-wispr-1.6.1264-evidence.json` and `/private/tmp/open-wisper-wispr-helper-1.6.1264-evidence.json`. They may contain proprietary source or embedded configuration and are deliberately outside Git. Temporary files are not durable archives; preserve them privately if needed before system cleanup. Both REA sessions were closed after export.

### Supplemental read-only source inspections

The S references identify direct filesystem/source observations, **not additional REA evidence records**. Main/preload offsets below are zero-based JavaScript UTF-16 string indices into decoded UTF-8 source, not machine addresses or byte offsets.

| Alias | Source / bounded location |
| --- | --- |
| S1 | Extracted `package.json`, SHA-256 `008bd8235c5791fefd3b0db64490c8fb94e1307018f8caf6de93eb1a2818619e`; outer `Contents/Info.plist` read using PlistBuddy. |
| S2 | Extracted `.webpack/main/index.js`, SHA-256 `35c12af54bcfaaf576443dd156dc194c075fc5da1b255ca48921371e1a092be7`. ASR request method at 3564828; dictation request region at 3643446; start guard region at 4436561; native adapter export region at 4561935; polish marker at 2720105; dictionary/snippet/style markers around 2922465. |
| S3 | Extracted `.webpack/renderer/dist/recorderWorklet.js`, SHA-256 `c2d5eba9275ae7d4831ea4c01fc426fe6c98d31097ac67d2c7ce12583f7029e2`; complete 2,331-byte file read. |
| S4 | Four packaged migration files listed below; complete schema bodies read without executing them. |
| S5 | Bounded directory listings of renderer entrypoints and packaged migrations; discovery only. |
| S6 | `/usr/bin/nm -u` on the exact helper executable above, filtered to AXUIElement, CGEvent, audio, and pasteboard imports; no native call execution. |
| S7 | Extracted `.webpack/renderer/hub/preload.js`, SHA-256 `e76b8dab262e3230e2993edea73fbb4db61736b4124c8bdff9ce7ee0f5d5e4de`; bridge region around 54400–55540. |

S4 files, relative to `Contents/Resources/migrations`, with SHA-256:

```text
20240510213006-create-history.js
9825d2f919759f3b8cb80ce7402048ed0bcd85fd44654a1daa026fbab6a4adc1
20250113230038-add-axtext.js
a5b24a1d410ae0054ef8a47b371161237763a658e426a6485b72a35d6250ae72
20240827224704-add-pasted-text-and-divergence-score.js
a99a7f4176006ed72eead66a7c628891680b629c4ae18e590a15048aa0bfd7df
20260106103849-create_polish_table.js
25fa8d3d24b0d1550c4831f6b947e32ca66c6834f980f1811e655c8cc4103914
```

## Questions revisited

| Question | Status | Follow-up authority needed |
| --- | --- | --- |
| What architecture is actually installed? | Answered within static scope | Electron package plus native helper identities established. |
| What are the main dictation subsystems? | Partially answered | Static entrypoints/request methods/schema surfaces found; complete execution path not traced. |
| How exactly does insertion work in different editors? | Unresolved | Consented controlled UI trials and/or native decompilation after Automation authorization. |
| Which ASR model, rewrite prompts, and backend pipeline are used? | Unresolved | Backend authority or documented provider details; client strings cannot establish them. |
| Are snippets, styles, and notes available to this account? | Unresolved | Controlled live UI inspection; markers can describe gated/unused code. |
| What are Wispr's latency, resource usage, and privacy defaults? | Unresolved | Separate consented runtime measurements and retention/network investigation. |
| Can we define two independent native implementations? | Answered as a design proposal | See the native plan and behavior contract; no parity claim. |

## November 1 insertion follow-up

The user reports that cursor insertion still fails. The focused static paste-path investigation and an independent candidate correction are complete. **The original cross-application failure has not been reproduced or verified as fixed, and Wispr equivalence has not been demonstrated.**

- The installed version remains **1.6.1264**. REA reopened the native helper and observed the same SHA-256, `78d232a48a80e6c823339ee5a683b8674f23e7e73d2c9fa8d123b49f455b2e10`. `inspect_macho` again produced E5, with its original incomplete import/export coverage. The initial follow-up search failed with `Not authorized to send Apple events to Hopper Disassembler.` No usable native decompilation resulted from that attempt.
- The existing extracted main bundle was read again and its SHA-256 still matched S2. A bounded region at UTF-16 offset **4574909** sends a `PasteText` request with a per-request identifier and text to the helper; the handler near **4516015** receives a separate paste outcome with success and elapsed time. This establishes static orchestration surfaces, not the helper's editor-specific delivery mechanism or runtime success. Native strings also include clipboard-provider and restoration-related names; those names alone do not establish timing or an algorithm.
- Open Wisper's installed `--check-delivery` queried the **running Swift app**, not a terminal-attributed child. It reported `automaticInsertion: true`, `accessibilityGranted: true`, and `eligibleFocusedField: true` while Chrome and, later, T3 Code were focused. Both observations included an `AXTextArea` with an `AXWebArea` ancestor. This rules out missing Accessibility permission and disabled insertion **at those observation times**, not at every prior failure. The readiness check neither attempts insertion nor reports the outcome of the preceding dictation.
- The Swift implementation was traced from Stop-time capture through selection/process revalidation, direct `AXSelectedText` replacement, and the single targeted Command-V fallback. The running app's review UI subsequently showed the message specific to its AX-success branch. This identifies the latest displayed delivery path, not the destination, whether text appeared, or the cause of all earlier failures. AX success remains an accepted request rather than observed insertion.
- A disposable Chrome profile with local plain-text and contenteditable fields was opened for a controlled probe. The standalone probe reported **no Accessibility or event-posting permission**, unlike the running packaged app, so it did not attempt insertion. The fixture window/profile is not evidence of a completed end-to-end test. The owned browser process was subsequently closed; the user's regular browser and active dictation were left running.

### Authorization recovery and supplemental native observations

The installed T3 build lacks the hardened-runtime Apple Events entitlement and usage-description key, so the earlier instruction to find its missing Automation toggle was not actionable. The user instead ran one prepared Terminal command using the existing pinned REA 6.8.0. Its helper procedure search succeeded: `ev_eee172d4bcaafd3d1199fb81a237f0555e3ffb205009a05a1fa232775ade3049`, saved in `/private/tmp/open-wisper-hopper-check.json`. No TCC reset, new login, or microphone/Accessibility reset was performed.

After loading the exact helper through Hopper's standard Mach-O importer, focused calls to its installed `HopperMCPServer` 1.0.0 API returned the following **supplemental vendor-native static observations**, not normalized REA Evidence and not executed helper behavior:

| Boundary | Observation | Limitations |
| --- | --- | --- |
| `0x1000fd960` → `0x1000ff96c` | The pasteboard data-provider callback supplies requested text, records that data was provided, and invokes the restoration scheduler at `0x1000fe514`. | Does not establish who requested the data or which branch a live dictation uses. |
| `0x1000fe514` | Checks restoration policy and whether restoration is already scheduled, then schedules main-queue work at dispatch time plus 0.5 seconds. Assembly at `0x1000fe848` loads IEEE-754 `0x3fe0000000000000` before the time addition. | Establishes request-triggered scheduling, not successful editor insertion or universal restoration. |
| `0x1000f7af0` and `0x1000f6454` | An immediate-clipboard path calls an event routine that creates a Command-modified key-down/up pair, posts through `CGEventPost` with tap value 1, and separates them by a 5 ms sleep. Another call site is `0x1000fca24`. | Not proof that global posting, modifier manipulation, or these delays are necessary for our app. Open Wisper retains PID-targeted delivery and does not copy this routine. |

Complete vendor results stay outside Git at `/private/tmp/open-wisper-hopper-vendor-20261101.json` (26 calls, file SHA-256 `d5a7c48829d03dcf9e9c5753f93bf6d559b60caa5045dc0c4877e1c93f1efc17`). Provider pseudocode is not original source, and the inspected slices do not enumerate every paste mode. The owned API subprocess was closed after saving; the proprietary helper was not launched.

### Independent correction and verification boundary

A private-pasteboard regression reproduced a concrete Open Wisper defect: a consumer reading 650 ms after the request received the original clipboard rather than the transcript because restoration had already occurred. It failed before the change and passed after lazy text provision and a bounded request wait were added. Restoration now follows a text request plus a 500 ms grace period, or a two-second no-request timeout; newer clipboard ownership and cancellation remain protected. A clipboard manager can request text too, so this is not an insertion acknowledgement.

Web content with an `AXWebArea` ancestor now uses the existing guarded, PID-targeted Paste path without first making an unvalidated AX write. A separate decision regression failed before that routing change and passed afterward, including unavailable event-posting access, one-time authorization, and clipboard preservation. This is our compatibility policy, not a recovered Wispr algorithm or proof that AX caused the user's failure. Native selected-text delivery and no-retry behavior for ambiguous AX writes remain unchanged.

All **77 Swift tests across 13 suites** passed; the release bundle and engine/model checks passed. The update is staged at `/private/tmp/open-wisper-insertion-update/Open Wisper Swift.app`, not installed or launched. The user's running installed app and in-memory transcript were preserved. Its ad-hoc designated requirement is tied to its code hash, and no usable code-signing identity is configured; after replacing the build, macOS may require renewed Accessibility approval. Do not promise permission continuity or reset existing grants preemptively.

Still needed: install after the user keeps any wanted transcript and quits the old process, then run controlled native/browser/contenteditable delivery trials. Session/global versus PID-targeted event routing, held modifiers, clipboard-manager interference, and external editor behavior remain unqualified.

Installation subsequently completed after the user confirmed quitting. The installed executable matches the tested staged build, with signature and profile checks passing. The reopened GUI reports Accessibility denied while the existing Settings row remains on; authorization renewal and controlled external-editor trials are still pending. See the installation checkpoint in `docs/swift-status.md`. No additional proprietary analysis or permission reset was performed during installation.

Authorization was subsequently repaired by removing only the stale Open Wisper Swift entry after the user's approval and macOS authentication, then re-adding the exact installed bundle. The actual running GUI now reports Accessibility granted, automatic insertion enabled, and an eligible T3 text field with an `AXWebArea` ancestor. The executable was not rebuilt or re-signed. This closes the permission/readiness gap only; no completed external-editor insertion trial or runtime Wispr observation is claimed. A later active Open Wisper recording was preserved untouched. See the authorization-repair checkpoint in `docs/swift-status.md`.

## Open-source boundary

### October 31 workflow correction

The user identified automatic insertion into the current text field on stopping dictation as an essential observed product behavior. This is a user-supplied behavioral requirement, separate from our static evidence. The initial Swift review-first default did not meet it. F03 (S2 and E5/S6) already established native text-box/paste interfaces and AX/CGEvent imports; it did not establish a reason to make review the primary workflow.

The saved E3 evidence was revisited through REA without reopening or executing the proprietary application. Its partial static coverage remains unchanged. The independent Swift implementation now captures the field at Stop, attempts direct selected-text replacement or guarded Paste, and keeps completion from activating the app. Exact Wispr helper algorithms and editor-specific reliability remain unknown; these Swift mechanisms and safeguards are our design choices.

Implement from the behavioral requirements and public OS/engine APIs. Do not commit extracted bundles, copied functions, private schemas/protocols, credentials, logos, or proprietary models. Do not call Wispr endpoints or reuse its authentication. This investigation is not a formally isolated clean-room process: an implementer has seen shipped code. Keep the implementation independently authored and seek separate review if a formal clean-room process is required.
