# AGENTS.md

Guidance for anyone working on this repo: people and coding agents (Claude Code, Codex,
Copilot, Cursor, ...). Read it before changing code.

## What this is

RMount (a fork of macsh by Ayon Pal) is a macOS (14+, Apple Silicon) menu-bar app that mounts remote storage as local
volumes without macFUSE. It wraps [rclone](https://rclone.org): for each remote it starts
`rclone serve webdav|nfs` on localhost and mounts that (WebDAV via NetFS, NFS via
`mount_nfs` under `~/rmount/<name>`). Backends today: SFTP, S3-compatible, FTP/FTPS,
WebDAV/Nextcloud, SMB and Google Drive (the generic `Backend.rclone` model; OAuth sign-in via
`OAuthAuthorizer`).

## Layout

- `Sources/RMountCore/` – all logic, no UI. Swift package (tools 5.9, links NetFS/Security).
  - `Models/` backend + remote models, `BackendDescriptor` (declarative backends)
  - `Rclone/` config builder, rclone process management
  - `Mount/` NetFS / `mount_nfs`; `Session/SessionManager` orchestrates mount/unmount
  - `Storage/` Keychain, `remotes.json`; `SSH/` host keys and key generation
  - `Update/` self-update: GitHub release lookup per channel, DMG download/verify/install
    (release asset names `rmount-*.dmg` / `rmount-lite-*.dmg` and nightly tags `nightly-YYYYMMDD-<sha>`
    are an interface; the app embeds its commit as `RMountBuildSHA`)
- `App/rmount/` – SwiftUI app, generated with xcodegen from `App/project.yml`
  (flavors `rmount` with bundled rclone and `rmount-lite`).
- `App/RMountFinder/` – Finder Sync badge extension; shares the snapshot schema with `RMountCore/Finder/`.
- `Tests/RMountCoreTests/` – unit and integration tests.
- `scripts/` – release build; `scripts/verify-dmg.sh` checks the built DMGs the way a user's Mac
  will (signature, layout, bundled rclone, Gatekeeper after a simulated download) and runs at
  the end of `build-release.sh`; `scripts/bench-mount.py` benchmarks a live mount (listing,
  upload and cold-read speed, measured on the wire with `nettop`); tests for both are in
  `scripts/tests/` (`python3 -m unittest discover -s scripts/tests`); `scripts/ci/` – servers
  used by the integration CI jobs.
- Homebrew: the casks live in the separate repo `fperdigon/homebrew-tap`. A `v*` tag runs
  `scripts/update-cask.sh`, which rewrites `version` and `sha256` there; it needs the repository secret
  `HOMEBREW_TAP_TOKEN` (a token that can push to the tap) and is skipped with a notice without it.
- `.github/workflows/` – `ci.yml` (build, tests, coverage, integration, app compile), `release.yml`.

## Build and test

macOS only (Security, NetFS, SwiftUI); it does not compile on Linux.

```
swift build
swift test                       # unit tests; integration tests skip themselves
swift test --enable-code-coverage
```

Integration tests are gated by `RMOUNT_IT_*` environment variables and are normally run by
CI (see below). Do not commit changes you could not compile or test; if you work in an
environment without macOS, open a PR and let CI be the judge.

### Running tests, and when a run hangs

- Run `swift test` yourself on the Mac; a coding agent's sandbox (Codex) can build but cannot run the suite
  (Application Support and Keychain writes are denied, `ps` is blocked), so it cannot verify tests. Have agents
  write code and tests, then run them here. Never give an agent an unsandboxed run without the user saying so.
- macOS has no `timeout`: bound every run with `perl -e 'alarm 600; exec @ARGV' swift test ...`, or a watcher that
  samples and kills a run that prints nothing for ~90 s. Use `--scratch-path` to keep a separate build for it.
  Always send output to a file and read the end of it; do not stream a whole run into your context.
- Never block a test on `Process.waitUntilExit()` after `terminate()`: Foundation can miss the wakeup and block
  forever although `isRunning` is already false and the pid is gone (this hung the whole suite; it only showed
  after `RcloneProcessTests` ran earlier in the same process). Stop children with `Process.stopAndReap()` from
  `TestSupport.swift` (terminate, poll `isRunning` with a deadline, SIGKILL fallback) and never leave a spawned
  child running at the end of a test.
- Opt-in debug logging, off by default and with no effect on output when unset: `RMOUNT_TEST_DEBUG=1` logs test
  start/finish, spawned processes (arguments redacted), terminate/wait calls, port binds, teardown blocks and a 5 s
  watchdog on `waitUntilExit`; `RMOUNT_TEST_DEBUG_FILE=<path>` also appends the lines to a file, which you need
  because `swift test` holds back the test process's stderr when a run stalls. Debug output must never reach a
  stream a test asserts on (the fake rclone writes only to the file).
- How to find a hang: reproduce with the flag on, take `sample <xctest pid> 3` and `lsof` when the log goes silent,
  then bisect by test class (`swift test list`, `--filter "RMountCoreTests\.(A|B)/"`), halve the set until a
  pair remains, then pair single methods. A class that passes alone can still hang in combination: a leaked
  process, port or Foundation state from an earlier test is the usual cause.
- Product code also uses `waitUntilExit()` (mounting, SSH keygen, host-key scan, connection tester, updater). Keep it
  off the main thread; if you touch one, consider a bounded wait.

## Ways of working

- Develop on a branch, open a PR against `main` on this repo, and keep CI green.
  CI runs on every PR and on pushes to `main`.
- Every push to `main` publishes a `nightly-YYYYMMDD-<sha>` pre-release (`scripts/publish-nightly.sh`;
  only the newest kept, change history carried forward; one release per commit because immutable
  releases never allow a tag name to be reused). A `v*` tag publishes a
  release; the tag must match `CFBundleShortVersionString` in
  `App/rmount/Resources/Info.plist` and `Info-Lite.plist`.
- Update `CHANGELOG.md` (Keep a Changelog format, `[Unreleased]` section) for user-visible
  changes. Update the README when adding a backend.
- Commit messages: short imperative subject, explain the why in the body.
- Keep changes focused; do not refactor unrelated code in a feature PR.
- This repo is a fork of `AyonPal/macsh`, and `gh pr create` defaults to the upstream parent. Always pass
  `--repo fperdigon/rmount` (and `--base`/`--head`) to `gh pr create`, `gh pr view`, `gh pr merge`, and check the URL it
  prints. A PR opened upstream by mistake must be closed at once with a short apology.
- Stacked PRs: base a PR on the branch it depends on (`--base <branch>`); GitHub retargets it to `main` when that
  branch merges. Merge them in order.
- Do not commit `AGENTS.md` edits that are not yours: stage files by name (`git add <paths>`), never `git add -A`.

## Code conventions

- Secrets (passwords, keys, tokens) live in the Keychain and reach rclone only through
  `RCLONE_CONFIG_R_<OPTION>` environment variables. They must never be written to the
  temporary rclone config, `remotes.json`, logs or error messages.
- Anything that blocks (rclone start-up, host-key scan, NetFS, `mount_nfs`) runs off the
  main thread; only state changes and dialogs use it.
- New backends are declared as data: add a `BackendDescriptor` (fields, which are secret)
  rather than another `Backend` case plus `switch` arms. See `BackendDescriptor.webdav`.
- Existing `remotes.json` files and Keychain items must keep working: decode tolerantly and
  do not rename stored keys without an alias (see "Legacy aliases").
- Match the surrounding style, naming and comment density.

## Testing rules

1. **Unit tests for all new logic**, using the helpers in `Tests/RMountCoreTests/TestSupport.swift`
   (`FakeRclone`, `FakeMounter`, temp dirs). Fix tests you break; never skip or delete a
   test to get green.
2. **Every backend must be tested for real in the CI pipeline.** A backend is not done until a
   CI job starts a real server of that kind and an integration test drives RMount's own
   pipeline against it: `SessionManager.add` -> `mount` (real rclone, real `Mounter`) ->
   write a file through the mount -> verify it arrived on the server -> `unmount`. Cover
   both mount protocols (NFS and WebDAV) and every auth method the backend offers (e.g.
   password, key file, generated key). Do not bypass RMount by calling the rclone CLI.
   - Servers are started by scripts in `scripts/ci/` and exported as `RMOUNT_IT_*`
     variables. Docker/Podman cannot run on Apple Silicon runners (no nested
     virtualization), so run servers natively (PHP for Nextcloud, small Python servers,
     `rclone serve`, ...).
   - Use `IntegrationHarness.roundTrip` and `IntegrationEnv.require` from
     `IntegrationSupport.swift`; tests skip when their variables are unset.
   - Current coverage: SFTP, FTP, S3 (`BackendIntegrationTests`) and Nextcloud/WebDAV
     (`NextcloudIntegrationTests`), SMB (`BackendIntegrationTests`), Azure Blob against Azurite and the raw-options escape hatch (`AzureIntegrationTests`), plus Google Drive (`GoogleDriveIntegrationTests`, needs the
     `RMOUNT_IT_GDRIVE_TOKEN` repository secret; they skip without it). Backblaze B2 and Google Cloud Storage have no emulator and run only with test-account secrets (`NativeCloudAccountTests`). Known gaps: FTPS/TLS, passphrase-protected keys, real
     cloud providers (OAuth backends such as Google Drive will need a stand-in server or
     a test-account secret; document the choice in the PR).
3. **New code must be at least 80% covered.** CI fails a pull request when less than 80% of the
   changed lines under `Sources/` are covered by the unit tests (the `New-code coverage gate`
   step of `build-test`, using `diff-cover` on the llvm-cov report; the per-line report is in the
   job summary). Code in `App/` (SwiftUI) is not part of the package and is not measured, so keep
   logic in `RMountCore` and the views thin. Do not lower the threshold or exclude files to pass.
   Overall coverage of `RMountCore` is ~89% lines; do not let it drop.
4. Real-world checks that CI cannot do (Finder behaviour, a real provider account) are
   listed in the PR description as manual steps.

## Verify in the macOS VM after every build (required)

Unit tests and CI do not show what the user sees. After any change that is compiled (code, UI, mount
behaviour, packaging), finish the work by building the release DMG and testing it in the UTM macOS test VM,
with screenshots. Do this before opening or merging the PR and again after meaningful fixes. A change that
only touches docs or CI files is exempt. If the VM cannot be used, say so in the PR; never claim it was tested.

Tools (user-level skill, not in this repo): `~/.claude/skills/utm-macos-vm/` (`SKILL.md`, `LESSONS.md`, `scripts/`).
Read `LESSONS.md` first and append what you learn. VM name: `rmount-test-base` (to be renamed `macos-test-base`;
`utmctl list` shows the current one). `S=~/.claude/skills/utm-macos-vm/scripts`. Guest login is in the skill's
`guest-account.txt`; never print it or commit it.

Flow:

1. **Compile and unit-test on the host**: `swift build`, `swift test --filter <the suites you touched>`. The
   full suite can hang on a developer Mac in an integration teardown; CI runs it.
2. **Build the DMG**: `./scripts/build-release.sh` -> `dist/rmount-<version>.dmg` (runs `verify-dmg.sh`).
3. **Start the VM** if needed (`utmctl start`), then `utmctl ip-address <vm>`. UTM can stay in the background.
4. **Copy and install** (`$S/vmssh.sh <vm> '<cmd>'`, `$S/vmssh.sh <vm> --put <file> <dir>`): detach every
   `/Volumes/rmount*` first (a stale mount makes you install the OLD app), `hdiutil attach`, replace
   `/Applications/rmount.app`, `xattr -dr com.apple.quarantine`, and check the binary size matches the host build.
   Kill the old app with `kill -9` (`pkill` only raises the quit dialog). The guest has no `python3`/CLT: use
   `sed`/`plutil`/`curl` there, or it pops an install prompt.
5. **Seed a remote** in the guest's `~/Library/Application Support/ai.rmount/remotes.json` (shape in the
   skill) pointing at a test server on the host (`rclone serve webdav <dir> --addr 192.168.64.1:18080`, the guest
   reaches the host at 192.168.64.1). Never use the user's real remotes or touch the user's running RMount.
6. **Throttle on purpose** when testing transfers: `bandwidthLimit` is rclone `--bwlimit` and is `UP:DOWN`
   (`10M:100M` = upload 10 MB/s). Use real large files (1-2 GB, `dd if=/dev/urandom` over SSH, the guest has
   space) so progress is observable for minutes. Compare checksums on the host after the queue drains.
7. **Drive the UI and take pictures**: `$S/vmctl.sh <vm> shot /path/x.png` (screen), `... click X Y`,
   `... key "text"`, `... sc <scancodes>` (make+break pairs). Open the menu-bar menu, every window or menu item
   you changed, the empty state, the error state and the busy state, and look at each image. Writes to a
   mounted volume must be typed into the guest's GUI Terminal (SSH gets EPERM from TCC); click that Terminal
   first so the keystrokes do not go to another window.
8. **Probe rclone directly** to confirm the UI is telling the truth (`$S/rcprobe.sh` in the guest prints
   `vfs/queue` and `core/stats`).
9. **Record the evidence**: put the screenshots in the PR description or a comment (attach files, or list what
   each shows), plus what was exercised, what was not, and any failure. Send the user the key screenshots.
10. **Clean up**: stop the host test server, delete the test files and seeded remotes, leave the VM in a known
    state, and add new findings to the skill's `LESSONS.md`.

Harness lessons: `--bwlimit` order is `UP:DOWN`; detach every `/Volumes/rmount*` before attaching a new DMG;
`vmctl.sh` takes the VM name first (`vmctl.sh <vm> shot FILE`); keystrokes go to the focused window, so click the
Terminal before typing; a Space (`sc 57,185`) first avoids losing the first typed characters; and the copy into a
mount returns in seconds (local cache), so judge uploads by `vfs/queue` and the Transfers window, and by a
checksum on the host after the queue drains.

Cover at least: first launch from the DMG (Gatekeeper), mount and read/write for both protocols NFS and WebDAV
when the change can affect them, the changed UI, quit/unmount guards when uploads are pending, and several
remotes at once when the change is per-remote. Keep the VM to what was installed for the test; do not enable
macOS security settings or sign in to an Apple account in it.

## Things to avoid

- Don't add dependencies without a reason; the core is dependency-free.
- Don't weaken host-key verification or certificate checks to make a test pass.
- Don't push tags or release from automation without the maintainer asking.
- Don't commit secrets, signing material or `.build/`.

## Legacy aliases (from the macsh name)

The app used to be called macsh. Every old name is still readable as an alias of the new one, in
one place, `Sources/RMountCore/Compat/LegacyNames.swift`. Aliases only read; nothing writes under an
old name, so an older version keeps working side by side.

| Old name | New name | Alias behaviour |
| --- | --- | --- |
| bundle ids `ai.macsh`, `ai.macsh.lite` | `ai.rmount`, `ai.rmount.lite` | `AppPaths` copies the old Application Support folder once; `KeychainService` falls back to the old service and copies the secret forward; `UserPreferences` copies the old domain's values |
| preference keys `macsh.*` | `rmount.*` | copied once per install (`rmount.legacyPreferencesMigrated`) |
| `~/macsh/<name>` NFS mounts | `~/rmount/<name>` | `Mounter` still looks there for leftover mounts |
| release assets `macsh-*.dmg` | `rmount-*.dmg` | `UpdateChecker.selectAsset` prefers new, accepts old; `UpdateInstaller.install` moves `macsh.app` to `rmount.app`. Releases no longer publish `macsh-*.dmg` (dropped: only two downloads ever, so no one was left to bridge) |
| Info.plist key `MacshBuildSHA` | `RMountBuildSHA` | `BuildInfo` falls back to the old key |
| CI secrets `MACSH_IT_*` | `RMOUNT_IT_*` | workflow uses `RMOUNT_IT_* \|\| MACSH_IT_*`; `IntegrationEnv.require` accepts both |

**Removal:** drop the aliases (delete `LegacyNames.swift` and each use, the `MACSH_IT_*` fallbacks) in the first release that is at least six months after
the first RMount release, or earlier once no install of macsh can still be updating. Do it in one PR,
and add a CHANGELOG line that old data is no longer migrated.

## Context hygiene: delegate to agents
- Always use agents (subagents / Codex agents) for work that produces bulky output or many tool calls (searches, long logs, test and eval runs, wide file reads, coding), so the main context stays clean.
- The main session plans, briefs, reviews the result and talks to the user; agents return only a short report with what matters.
- Do not pull raw logs, full diffs or large files into the main context when an agent can summarize them.
