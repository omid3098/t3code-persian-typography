# T3 Code Persian Typography

Vazirmatn and smart Persian/English direction for the **main T3 Code desktop
app** on Windows. The normal T3 Code shortcut gets the feature; there is no
separate launcher.

The runtime:

- uses the vendored [Vazirmatn](https://github.com/rastikerdar/vazirmatn) font for Persian letters only, keeping your chosen UI font (including one set in T3 Code's settings) for Latin text and leaving code fonts alone;
- makes every chat paragraph, heading, list item, table cell, folded section, user message, and the composer RTL as soon as it contains even one Persian letter, however much English it also holds;
- keeps English text, code, paths, URLs, email addresses, and hashes LTR;
- isolates Persian thread titles, project names, and other short labels without flipping the LTR app shell;
- recomputes direction while responses stream and while you type.

## Install

Requirements: Windows and T3 Code desktop. Node.js 18+ is used when present;
otherwise the scripts run on T3 Code's own bundled runtime. Run it from any
terminal, including one **inside** T3 Code:

```powershell
git clone https://github.com/omid3098/t3code-persian-typography.git
cd t3code-persian-typography
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If T3 Code is closed, the patch is applied right away. If T3 Code or its
updater is running, the installer doesn't wait or fail. It registers the
auto re-patch watcher (below) and returns immediately, and the watcher applies
the patch a few seconds after you fully close T3 Code. Either way, the next time
you open T3 Code it has Persian typography. Every run is logged to
`%LOCALAPPDATA%\T3CodePersianTypography\install.log`.

T3 Code serves its renderer from `resources\server.asar`. The installer adds
the runtime to that archive's `apps/server/dist/client` and loads it from
`index.html`. It does not repack the archive: the original data is copied byte
for byte, three files are appended, and only the archive header changes, so
the unpacked native modules in `server.asar.unpacked` keep their exact entries.
It does not modify the T3 Code executable, `app.asar`, the updater, settings,
or threads. Before the first patch it saves the exact original here:

```text
%LOCALAPPDATA%\T3CodePersianTypography\server.asar.backup
```

## Verify

```powershell
npm test
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

`doctor.ps1` runs the tests and checks the patched payload, recorded SHA-256
hashes, backup, runtime version, the auto re-patch watcher, and the T3 Code
executable signature.

`tests\watch.e2e.ps1` exercises install, auto re-patch, and uninstall against
a throwaway copy of the installed T3 Code: installing while T3 Code runs, an
update while closed, "Restart to update" both when the watcher wins the race
and when T3 Code opens the build first (with a T3 Code helper that outlives
it), a half-written file, a runtime upgrade, and an update prepared ahead from
its downloaded installer (about four minutes):

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\watch.e2e.ps1
```

## Direction behavior

Any block that contains at least one Persian (Arabic-script) letter gets
`dir="rtl"`, even when most of its letters are English. A block with Latin
letters and no Persian gets `dir="ltr"`. Paragraphs, headings, list items, and
table cells are decided one by one, so each line follows its own text. A folded
section (T3 Code draws an HTML `<details>` as its own collapsible) gets its title
and its content decided the same way; in an RTL title the closed chevron is
mirrored so it points at the text. URLs, paths, email addresses, and hashes
don't count, and code blocks, inline code, and the terminal stay LTR. An empty
composer uses `dir="auto"`.

Outside chat content, T3 Code keeps its LTR shell. Only text-only elements that
contain Persian letters (such as a thread title) get a direction, and their
alignment is left to the app.

## T3 Code updates (automatic)

Every T3 Code update replaces `server.asar`, and the Nightly channel updates
often. `install.ps1` therefore registers a per-user logon task,
**T3CodePersianTypography**, that runs `watch.ps1` hidden (no admin rights
needed). When an update replaces `server.asar`, the watcher backs up the new
original and re-applies the patch on its own. You don't need to do anything.

How it stays ahead of "Restart to update", which relaunches T3 Code the moment
the updater's installer exits:

- As soon as the updater has downloaded an update, before "Restart to update"
  runs it, the watcher takes `server.asar` out of the downloaded installer
  with Windows' own `tar.exe` and prepares the patched build (about 7 seconds;
  it is kept in `%LOCALAPPDATA%\T3CodePersianTypography\prepared-next`). It
  reads the installer with full sharing, which never blocks the updater.
- While the installer runs, the watcher reads the new `server.asar` with full
  sharing, which never blocks the installer. If it has exactly the SHA-256 of
  the build prepared ahead, that build is ready to swap. Otherwise (for
  example the download finished while the watcher was not running, or
  `tar.exe` could not read the installer) the watcher checks the snapshot
  against the build's own per-file SHA-256 hashes, so a half-written build is
  never patched, and prepares the patched build next to it.
- The moment the installer exits, the watcher swaps the prepared build in
  with one atomic `MoveFileEx`. In tests this takes 20 to 100 ms. The
  installer starts T3 Code just before it exits, so a fast T3 Code can still
  get there first.
- Windows refuses that rename while any process has `server.asar` open. If
  T3 Code got there first, nothing changes; the watcher tries again every 10
  seconds and applies the patch as soon as T3 Code is fully closed, even if a
  helper started with T3 Code's executable (such as its device daemon) keeps
  running.
- The watcher never writes `server.asar` while the installer runs and never
  closes T3 Code.

The watcher logs only state changes (with millisecond timestamps, including
how long each swap took after the installer exited) to
`%LOCALAPPDATA%\T3CodePersianTypography\watch.log`. To install without it, pass
`-NoAutoRepatch`; rerun `install.ps1` without it to turn it back on.

## Compatibility

The runtime relies on T3 Code's internal renderer markup
(`data-testid="composer-editor"`, `.chat-markdown`, `data-timeline-root`,
`data-user-message-body`, `data-thread-item`) and its `--font-sans` and
`--font-composer` variables. These are not a public API. Before replacing
`server.asar`, the installer checks that these anchors still exist in that
build. If one is missing, installation stops before changing T3 Code and
reports which one needs updating.

## Uninstall

Quit T3 Code, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

The uninstaller removes the auto re-patch task and stops its watcher, then
restores the exact recorded original `server.asar`. If T3 Code
changed since installation, it refuses to restore a backup from a different
build and leaves the installation untouched (an update already removed the
patch in that case).

## Security and privacy

All runtime code and the font are local repository files served by T3 Code's
own origin, so they fit the app's existing content-security policy. There is
no network access, debugging port, CDN, or content logging. The runtime changes
DOM `dir` attributes, a font-stack CSS variable, and CSS only; it never rewrites
message text or stored data.

## Licenses

- Runtime and installer: [MIT](LICENSE)
- Vazirmatn font: [SIL Open Font License 1.1](fonts/OFL.txt)

Vazirmatn is Copyright © 2015–2022 Saber Rastikerdar and contributors.
