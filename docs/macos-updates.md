# macOS updates and permission continuity

## Chosen direction (November 2, 2026)

The user does not want to enroll in or configure an Apple Developer account.
Keep the current ad-hoc signing workflow for development; certificate enrollment,
notarization, and keychain/trust changes are not part of the current work.
Repeated macOS permission approval may therefore remain necessary after rebuilds.

Keep Sparkle as a future option, but revisit it **after implementing the Rust app
and polishing the UI**, not before or during those tasks. No updater, appcast,
update-signing key, or release service should be configured now. The research
below is retained for that later decision; Apple Developer setup is not a
prerequisite for continuing development or using the current app.

For now, update the installed native app at its existing path, after preserving
any transcript and quitting it:

```sh
OPEN_WISPER_APP_DIR='/Applications/Open Wisper Swift.app' \
bash native/swift/scripts/build-app.sh && \
open '/Applications/Open Wisper Swift.app'
```

This uses the existing ad-hoc default, cached models, and staged replacement.
There are no app-account logins or MFA steps in this workflow. Required macOS
consent is not bypassed or automatically granted.

## Finding (November 2, 2026)

The installed native app at `/Applications/Open Wisper Swift.app` currently has
an ad-hoc signature. Its observed designated requirement is a `cdhash` requirement,
which identifies that particular executable, not a durable developer identity.
Changing the executable changes that identity. Keeping the bundle identifier
alone does not make rebuilt ad-hoc binaries equivalent for macOS privacy checks.

`security find-identity -v -p codesigning` reported **zero valid signing
identities visible to this session**. This is not proof that the user has no
Apple Developer membership or that another keychain cannot provide an identity.
No certificate, private key, keychain trust setting, or privacy grant was created
or modified during this investigation.

The native Swift implementation needs microphone consent and Accessibility for
automatic cursor insertion. It uses a Carbon hotkey and local whisper.cpp, not
an event tap or Apple's Speech framework. It does **not** request Input Monitoring
or Speech Recognition authorization. If those prompts appear, first identify
whether the Electron app, another app copy, or the terminal is asking; do not
grant extra permissions as a workaround. Review-only dictation does not need
Accessibility. These findings are specific to the native Swift app.

## Optional durable-signing research (not selected)

1. Use one installed bundle path and the same durable code-signing identity for
   every build. An existing Apple Development identity can be used for local
   development; Developer ID Application signing is the distribution path.
   A deliberately managed self-signed identity is a local-only alternative, not
   equivalent to Developer ID or notarization. Do not recreate its key per build.
2. Keep any transcript, quit the app, then use the existing one-command build
   with a signing identity installed in the login keychain:

   ```sh
   SIGNING_IDENTITY='YOUR EXISTING CODE-SIGNING IDENTITY' \
   OPEN_WISPER_APP_DIR='/Applications/Open Wisper Swift.app' \
   bash native/swift/scripts/build-app.sh && \
   open '/Applications/Open Wisper Swift.app'
   ```

3. The initial move from the existing ad-hoc app to a certificate-backed identity
   may require one more microphone/Accessibility approval. Subsequent releases
   must keep the same bundle ID and satisfy the previous designated requirement.
   Verify permission continuity with two genuinely different builds on the target
   macOS release; macOS remains the authority and continuity is not guaranteed.

Expected effort: **zero app-account logins or MFA prompts** for a normal local
build with already-unlocked signing credentials; Keychain can still request
authorization to use its signing key. Initial Apple certificate enrollment and
release/notarization credential setup are separate one-time operations and can
require Apple authentication/MFA. Do not run separate login steps per artifact.
Never reset TCC, edit its database, disable SIP, or relax a signing requirement
to an identifier-only check to avoid consent.

Changing the selected bundled model is a settings change: it must not replace
the app executable, modify signed resources, or request privacy access again.
Only code changes require rebuilding/relaunching. Live patching Swift files
inside the installed bundle is neither the proposed update mechanism nor a fix
for a changing code identity.

## Future over-the-air design (deferred until Rust and UI polish)

Use **Sparkle 2** for conventional signed macOS app updates, rather than a custom
download-and-execute updater. OTA delivery makes installation easier; stable
code identity addresses permission continuity. One does not replace the other.

- Add a programmatic `SPUStandardUpdaterController` and a **Check for Updates…**
  menu item. Configure an HTTPS appcast and the project's own `SUPublicEDKey`.
  Select and pin a supported patched release when implementing; recheck Sparkle's
  security advisories rather than copying an old version number from this plan.
- Keep private update-signing keys in Keychain or a release-secret store, never
  in this repository, the bundle, the feed server, or shell arguments. Sign update
  archives with Sparkle's Ed25519 tooling and follow the eventual app-signing
  and distribution policy. Developer ID/notarization is
  a researched option, not a requirement accepted by the user. The Ed25519 key
  does not itself establish a stable macOS privacy identity.
- Version every distributed build with increasing `CFBundleVersion`. Build and
  sign nested executables inside out, then sign the outer bundle. Do not mutate
  bundled model bytes after signing. Validate hashes and the final bundle before
  uploading an archive and publishing its appcast entry.
- Leave model files at stable paths with identical bytes between code-only
  releases. Generate Sparkle delta updates so unchanged large models need not
  be downloaded each time; retain a complete archive as the fallback.
- Do not interrupt recording or discard an undelivered transcript for an update.
  Let users defer installation until idle; finish cancellation/worker cleanup
  before relaunch. Never kill a running app and silently replace its bundle.
- Test rejected/tampered archives, failed downloads, offline launch, full-update
  fallback, an unwritable installation directory, rollback/recovery, and privacy
  grants across two differently compiled signed versions. Installer authorization
  may be needed when the destination is not writable; do not promise no system
  prompts in every environment.

If this work is resumed later, first agree on a distribution/signing strategy
that respects the no-Apple-Developer-account decision, an HTTPS release/appcast
destination, an update-signing key, and a release/version policy. Hardened runtime,
microphone entitlements, and notarization are additional considerations if that
distribution route is chosen, not setup to perform now. No feed or keys are
invented, and no nonfunctional updater is enabled in this change.

## Primary references

- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
  — subsystem identity tracking, designated requirements, self-signed identities,
  resource seals, and inside-out signing.
- [Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  — requirements and code identity.
- [Sparkle setup and security](https://sparkle-project.org/documentation/)
  — programmatic integration, Developer ID, HTTPS and Ed25519 signing.
- [Sparkle delta updates](https://sparkle-project.org/documentation/delta-updates/)
  — unchanged-file layout, patch verification, and full-update fallback.
- [Sparkle security and reliability changes](https://sparkle-project.org/documentation/security-and-reliability/)
  — check before selecting the updater version.
