# T3 Code Persian Typography

This repository adds Vazirmatn and smart Persian/English direction to the main
T3 Code desktop app on Windows.

## Installation task

When a user asks to install or update this repository:

1. **T3 Code.** Look for `T3 Code*.exe` in `%LOCALAPPDATA%\Programs\t3code` and `%LOCALAPPDATA%\Programs\T3 Code`. If it is missing, download the Windows installer for this computer's architecture from https://github.com/pingdotgg/t3code/releases/latest and run it. If T3 Code is installed elsewhere, pass its path to `install.ps1` with `-T3Exe`. Done when the executable exists.
2. **Repository.** If `git` is missing, run `winget install --id Git.Git -e`. Clone https://github.com/omid3098/t3code-persian-typography.git, or run `git pull` in an existing clone. Leave Node.js as it is: the scripts run without it. Done when the repository root is the current folder and up to date.
3. Run `powershell -ExecutionPolicy Bypass -File .\install.ps1` from the repository root. Inside a running T3 Code this is fine: the installer hands the patch to the watcher (state `pending`), which applies it once T3 Code and its updater have exited.
4. Tell the user to fully close T3 Code once and reopen it; check `install.log` and `watch.log` in `%LOCALAPPDATA%\T3CodePersianTypography` if it did not apply.
5. Run `powershell -ExecutionPolicy Bypass -File .\doctor.ps1`. It also runs the tests. Done when it prints `Doctor passed`; `Pending` means T3 Code is still open.
6. Launch T3 Code from its normal shortcut and verify one Persian thread (title, message, and composer).
7. T3 Code updates replace `resources\server.asar`; the `T3CodePersianTypography` logon task (`watch.ps1`) re-applies the patch automatically. Check `%LOCALAPPDATA%\T3CodePersianTypography\watch.log` if it did not.
8. If the renderer-contract check fails, update the selectors in `runtime/runtime.js` and `RENDERER_CONTRACTS` in `tools/asar-patch.mjs` together; do not bypass the check.

The installer patches `resources\server.asar` (the renderer is
`apps/server/dist/client` inside it) and preserves the exact original at
`%LOCALAPPDATA%\T3CodePersianTypography\server.asar.backup`. `uninstall.ps1`
restores that backup only when its recorded hashes still match.

`watch.ps1` may read `server.asar` and the updater's downloaded installer only
with full sharing (never blocking the updater), must patch only a snapshot
that `verifyArchiveBuffer` accepts, must use a build prepared ahead from the
downloaded installer only when the installed `server.asar` has exactly its
SHA-256, must never write `server.asar` while the updater's installer runs,
must swap only with an atomic `MoveFileEx` (which fails while T3 Code has the
file open), and must never close T3 Code. While T3 Code may hold the file it
keeps retrying the swap: a process named like T3 Code (such as its device
daemon, which outlives T3 Code) does not prove that `server.asar` is open. Run
`tests\watch.e2e.ps1` after changing the watcher or installer.

`tools/asar-patch.mjs` must keep appending to the archive rather than
repacking it: `server.asar` has unpacked native modules that a repack can drop.

Do not create a separate launcher or shortcut. Do not use `NODE_OPTIONS`, a
remote-debugging port, or a remote-debugging pipe. Do not modify the T3 Code
executable, `app.asar`, the updater, T3 Code settings, stored threads, or
message text. The runtime changes renderer presentation only.

Keep the prose-block rules scoped to chat content (`.chat-markdown`,
`[data-timeline-root]`, the composer, user messages). Outside it, only
text-only, non-flex labels that contain Persian letters get a `dir`, without
`text-align`, so the LTR shell and centered headings keep their layout.
