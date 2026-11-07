import crypto from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { inspect, prepare, readArchive, readEntry, CLIENT_DIR, verifyArchiveBuffer } from "./asar-patch.mjs"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex").toUpperCase()
const version = JSON.parse(fs.readFileSync(path.join(repoRoot, "package.json"))).version

export function defaultStateDir() {
  const sudoUser = process.env.SUDO_USER
  const home = sudoUser
    ? fs.readFileSync("/etc/passwd", "utf8").split("\n").find((line) => line.split(":")[0] === sudoUser)?.split(":")[5]
    : os.homedir()
  if (!home) throw new Error("Cannot determine the invoking user's home. Pass --state-dir.")
  return path.join(sudoUser ? path.join(home, ".local/share") : process.env.XDG_DATA_HOME || path.join(home, ".local/share"), "T3CodePersianTypography")
}

export function findAsar() {
  for (const root of ["/opt/T3 Code (Beta)", "/opt/T3 Code", "/opt/t3code", "/usr/lib/t3code", "/usr/share/t3code"]) {
    for (const name of ["server.asar", "app.asar"]) {
      const file = path.join(root, "resources", name)
      if (fs.existsSync(file)) return file
    }
  }
  throw new Error("T3 Code archive not found. Pass --asar /path/to/resources/app.asar. AppImage/Snap/Flatpak read-only images are not supported.")
}

export function runningProcesses(asar) {
  const appRoot = path.dirname(path.dirname(asar)) + path.sep
  const found = []
  for (const pid of fs.readdirSync("/proc").filter((name) => /^\d+$/.test(name))) {
    try {
      const executable = fs.readlinkSync(`/proc/${pid}/exe`).replace(/ \(deleted\)$/, "")
      if (executable.startsWith(appRoot)) found.push(Number(pid))
    } catch (error) {
      if (!["ENOENT", "EACCES", "EPERM", "ESRCH"].includes(error.code)) throw error
    }
  }
  return found
}

function validated(file) {
  const error = verifyArchiveBuffer(fs.readFileSync(file))
  if (error) throw new Error(`Invalid archive ${file}: ${error}`)
}

function readState(stateDir) {
  return JSON.parse(fs.readFileSync(path.join(stateDir, "state.json"), "utf8"))
}

function writeState(stateDir, state) {
  const temporary = path.join(stateDir, `state-${process.pid}.tmp`)
  fs.writeFileSync(temporary, JSON.stringify(state, null, 2) + "\n", { flag: "wx", mode: 0o644 })
  fs.renameSync(temporary, path.join(stateDir, "state.json"))
}

function withLock(stateDir, callback) {
  fs.mkdirSync(stateDir, { recursive: true, mode: 0o755 })
  const lock = path.join(stateDir, ".lock")
  fs.mkdirSync(lock)
  try { return callback() } finally { fs.rmdirSync(lock) }
}

// Rename only after checking the build again; never rewrite an open archive.
function replaceArchive(source, target, expectedHash) {
  if (runningProcesses(target).length) throw new Error("Fully close T3 Code and its helpers before installing or uninstalling.")
  if (hash(target) !== expectedHash) throw new Error("T3 Code changed during the operation. Retry after its updater finishes.")
  const metadata = fs.statSync(target)
  const temporary = `${target}.t3pt-${process.pid}.tmp`
  try {
    fs.copyFileSync(source, temporary, fs.constants.COPYFILE_EXCL)
    fs.chmodSync(temporary, metadata.mode & 0o777)
    if (process.getuid() === 0) fs.chownSync(temporary, metadata.uid, metadata.gid)
    const fd = fs.openSync(temporary, "r")
    try { fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
    if (hash(target) !== expectedHash) throw new Error("T3 Code changed during the operation; installation stopped.")
    if (runningProcesses(target).length) throw new Error("T3 Code started during installation; close it and retry.")
    fs.renameSync(temporary, target)
    const directory = fs.openSync(path.dirname(target), "r")
    try { fs.fsyncSync(directory) } finally { fs.closeSync(directory) }
  } finally { fs.rmSync(temporary, { force: true }) }
}

export function install({ asar, stateDir, prepareOnly = false }) {
  asar = fs.realpathSync(asar)
  return withLock(stateDir, () => {
    if (fs.existsSync(path.join(stateDir, "state.json")) && readState(stateDir).asar !== asar) {
      throw new Error("State belongs to a different installation. Choose a separate --state-dir.")
    }
    validated(asar)
    if (inspect(asar).patched) {
      if (!fs.existsSync(path.join(stateDir, "state.json"))) {
        throw new Error("Archive is already patched but recovery state is missing. Use the original --state-dir; do not overwrite the backup.")
      }
      const existing = doctor({ stateDir })
      return existing
    }
    const sourceHash = hash(asar)
    const buildDir = path.join(stateDir, "builds", sourceHash)
    fs.mkdirSync(buildDir, { recursive: true })
    const result = prepare({ source: asar, outDir: buildDir, repoRoot })
    if (result.incomplete || !result.preparedSha256) throw new Error(`Cannot prepare archive: ${result.incomplete || "already patched"}`)
    const prepared = path.join(buildDir, "prepared.asar")
    validated(prepared)
    const state = {
      asar, backup: path.join(buildDir, "original.asar"), prepared,
      originalSha256: result.sourceSha256, patchedSha256: result.preparedSha256,
      runtimeVersion: result.runtimeVersion,
    }
    // Persist recovery information before touching the installed application.
    writeState(stateDir, state)
    const running = runningProcesses(asar).length > 0
    let writable = true
    try { fs.accessSync(path.dirname(asar), fs.constants.W_OK) } catch { writable = false }
    if (prepareOnly || running || !writable) return { status: "prepared", running, needsRoot: !writable, ...state }
    replaceArchive(prepared, asar, sourceHash)
    return doctor({ stateDir })
  })
}

export function doctor({ stateDir }) {
  const state = readState(stateDir)
  if (hash(state.backup) !== state.originalSha256) throw new Error("Backup hash mismatch; do not restore it.")
  const actual = hash(state.asar)
  if (actual === state.originalSha256) return { ...state, status: "prepared-or-restored" }
  if (actual !== state.patchedSha256) throw new Error("Installed archive changed, probably after an update. Rerun install.sh; the old backup will not be restored.")
  validated(state.asar)
  const result = inspect(state.asar)
  if (!result.patched || result.runtimeVersion !== version) throw new Error("Runtime is missing or outdated. Uninstall with the matching version before upgrading the runtime.")
  const archive = readArchive(state.asar)
  let client = archive.header
  for (const segment of CLIENT_DIR) client = client.files[segment]
  for (const [name, relative] of [["runtime.js", "runtime/runtime.js"], ["runtime.css", "runtime/runtime.css"], ["Vazirmatn.woff2", "fonts/Vazirmatn[wght].woff2"]]) {
    if (!readEntry(archive, client.files.t3pt.files[name]).equals(fs.readFileSync(path.join(repoRoot, relative)))) throw new Error(`Payload mismatch: ${name}`)
  }
  return { ...state, status: "healthy" }
}

export function uninstall({ stateDir }) {
  return withLock(stateDir, () => {
    const state = readState(stateDir)
    if (hash(state.backup) !== state.originalSha256) throw new Error("Backup hash mismatch; refusing to restore.")
    const actual = hash(state.asar)
    if (actual === state.originalSha256) return { status: "restored", asar: state.asar }
    if (actual !== state.patchedSha256) throw new Error("Refusing to restore a backup from a different build.")
    validated(state.backup)
    replaceArchive(state.backup, state.asar, state.patchedSha256)
    if (hash(state.asar) !== state.originalSha256) throw new Error("Restoration verification failed.")
    return { status: "restored", asar: state.asar }
  })
}

function main(argv) {
  if (process.platform !== "linux") throw new Error("This installer is for Linux only.")
  const [command, ...args] = argv
  const options = { stateDir: defaultStateDir() }
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--prepare-only") options.prepareOnly = true
    else if (["--asar", "--state-dir"].includes(args[i]) && args[i + 1] && !args[i + 1].startsWith("--")) {
      const key = args[i] === "--asar" ? "asar" : "stateDir"
      options[key] = path.resolve(args[++i])
    }
    else throw new Error(`Unknown or incomplete option: ${args[i]}`)
  }
  if (!["install", "doctor", "uninstall"].includes(command)) throw new Error("Usage: linux.mjs install|doctor|uninstall [--asar FILE] [--state-dir DIR] [--prepare-only]")
  if (command !== "install" && (options.prepareOnly || options.asar)) throw new Error("--asar and --prepare-only are only valid for install.")
  if (command === "install") options.asar ||= findAsar()
  const result = { install, doctor, uninstall }[command](options)
  console.log(JSON.stringify(result, null, 2))
  if (result.status === "prepared") console.log("Patch prepared. Fully close T3 Code, then rerun install.sh with sudo if needsRoot is true. The running app was not modified.")
  if (result.status === "healthy") console.log("Doctor passed.")
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)) } catch (error) { console.error(error.message); process.exitCode = 1 }
}
