# Linux installation

The Linux installer uses the shared Vazirmatn runtime and append-only ASAR
patcher. It supports writable unpacked T3 Code installations with
`resources/app.asar` or `resources/server.asar`. In the Linux package the
renderer is inside `app.asar`; only its client index and three presentation
assets are changed. Other archive entries, native modules, settings and
conversations are preserved. No separate launcher is created.

Requirements: Linux, Bash and Node.js 18 or newer (`node --version`).
No npm dependencies are needed. Read-only AppImage, Snap and Flatpak images
are not supported: use an unpacked desktop installation instead.

Clone the repository before following the commands below:

```bash
git clone https://github.com/omid3098/t3code-persian-typography.git
cd t3code-persian-typography
```

## Install

Fully quit T3 Code and wait for its updater to finish, then run from this folder:

```bash
./install.sh
```

For a system installation under `/opt` or `/usr`, run:

```bash
sudo ./install.sh
./doctor.sh
```

`sudo` is used only because system application files belong to root. With sudo,
state defaults to the invoking user's `~/.local/share/T3CodePersianTypography`.
For a normal user it respects `XDG_DATA_HOME`; when using a custom location,
pass the same explicit `--state-dir` to install, doctor and uninstall with sudo.
To locate a nonstandard installation or choose a state directory:

```bash
sudo ./install.sh --asar '/path/to/resources/app.asar' --state-dir "$HOME/.local/share/T3CodePersianTypography"
./doctor.sh --state-dir "$HOME/.local/share/T3CodePersianTypography"
```

If T3 Code is still running or the resources directory is not writable, the
installer only prepares the patch and prints `status: prepared`. It does not
close T3 Code or change the installed archive. Fully quit the app and rerun
with the required permissions. `--prepare-only` always stops after preparation.
Reopen T3 Code using its usual launcher after installation. Check Persian
messages, thread titles and the composer; code and English text should stay LTR.

## Verify and uninstall

```bash
./doctor.sh
# Fully quit T3 Code before restoring:
sudo ./uninstall.sh
```

The doctor checks installed and backup SHA-256 hashes, archive integrity,
runtime version and exact runtime/CSS/font bytes. It prints `Doctor passed`
only for a healthy installed patch. `prepared-or-restored` means the original
archive is still installed. Backups are kept per original build in
`builds/<SHA256>/original.asar`; uninstall restores only the exact matching
build and refuses to overwrite an updated or otherwise modified application.
Prepared archives and backups are kept after uninstall for recovery.

Installation uses a lock, prepares a complete verified copy, checks that the
source build has not changed, and atomically renames a sibling file while the
app is closed. Keep the updater closed during install/uninstall too; the
installer cannot coordinate with an unrelated package manager updating files.
If an interrupted installer leaves `.lock` in the state directory, first make
sure no installer is running, then remove the empty lock directory and retry.

## Updates and tests

After a T3 Code update, fully close it and rerun `sudo ./install.sh` (or
`./install.sh` for a user-owned installation). This version does not install a
background watcher. For a typography runtime upgrade, uninstall using the old
copy before replacing it, then install the new copy.

```bash
npm run check
npm run test:linux
# Also test against an unpatched real Linux build, without changing the installed app:
T3PT_TEST_ASAR='/opt/T3 Code (Beta)/resources/app.asar' npm run test:linux
```

The integration check patches and restores a temporary copy and requires
enough free disk space for several archive copies. Tests cover repeated
installation, exact restore, application helpers still running, corrupted
backups, changed builds, incomplete archives and concurrent installers.
The regular `npm test` and `npm run check` commands include Linux tests on
Linux and skip those tests on other platforms. CI runs the shared tests on
Windows and both the minimum supported Node.js version and Node.js 22 on Linux.
If your installed archive is already patched, set `T3PT_TEST_ASAR` to the
matching `original.asar` backup printed by `doctor.sh` instead.
