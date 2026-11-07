import assert from "node:assert/strict"
import { writeArchive } from "./asar-fixture.mjs"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawn, spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { install, doctor, uninstall, runningProcesses } from "../tools/linux.mjs"
import { inspect, RENDERER_CONTRACTS } from "../tools/asar-patch.mjs"

if (process.platform !== "linux") {
  console.log("Linux installer checks skipped on this platform.")
  process.exit(0)
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "t3pt-linux-"))
const asar = path.join(temp, "application", "resources", "app.asar")
const stateDir = path.join(temp, "state")

function fixture(label = "original") {
  const file = path.join(temp, "fixture.asar")
  writeArchive(file, {
    "package.json": label,
    apps: { server: { dist: { client: {
      "index.html": "<html>\n<head>\n</head>\n</html>",
      assets: { "index.js": RENDERER_CONTRACTS.join(" ") },
    } } } },
  })
  return fs.readFileSync(file)
}

let helper
try {
  fs.mkdirSync(path.dirname(asar), { recursive: true })
  const original = fixture()
  fs.writeFileSync(asar, original, { mode: 0o644 })

  assert.equal(install({ asar, stateDir, prepareOnly: true }).status, "prepared")
  assert.deepEqual(fs.readFileSync(asar), original, "preparing must not modify the app")
  assert.equal(doctor({ stateDir }).status, "prepared-or-restored")
  if (process.getuid() !== 0) {
    fs.chmodSync(path.dirname(asar), 0o555)
    try {
      assert.equal(install({ asar, stateDir }).needsRoot, true)
      assert.deepEqual(fs.readFileSync(asar), original)
    } finally { fs.chmodSync(path.dirname(asar), 0o755) }
  }
  assert.equal(install({ asar, stateDir }).status, "healthy")
  const patched = fs.readFileSync(asar)
  assert.equal(inspect(asar).patched, true)
  assert.equal(fs.statSync(asar).mode & 0o777, 0o644)
  assert.equal(install({ asar, stateDir }).status, "healthy")
  assert.deepEqual(fs.readFileSync(asar), patched, "reinstall must be idempotent")
  assert.throws(() => install({ asar, stateDir: path.join(temp, "missing-state") }), /recovery state is missing/)
  const otherAsar = path.join(temp, "other", "resources", "app.asar")
  fs.mkdirSync(path.dirname(otherAsar), { recursive: true })
  fs.writeFileSync(otherAsar, original)
  const previousState = fs.readFileSync(path.join(stateDir, "state.json"))
  assert.throws(() => install({ asar: otherAsar, stateDir }), /different installation/)
  assert.deepEqual(fs.readFileSync(path.join(stateDir, "state.json")), previousState)
  assert.deepEqual(fs.readFileSync(otherAsar), original)

  // Even an unrelated surviving helper in the app directory blocks a swap.
  const executable = path.join(temp, "application", "sleep")
  fs.copyFileSync("/bin/sleep", executable)
  fs.chmodSync(executable, 0o755)
  helper = spawn(executable, ["60"])
  let helperError = ""
  helper.stderr.on("data", (chunk) => { helperError += chunk })
  await new Promise((resolve, reject) => { helper.once("spawn", resolve); helper.once("error", reject) })
  for (let attempt = 0; attempt < 100 && !runningProcesses(asar).includes(helper.pid); attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.ok(runningProcesses(asar).includes(helper.pid), `helper ${helper.pid} exit=${helper.exitCode} signal=${helper.signalCode}: ${helperError}; archive ${asar}`)
  assert.throws(() => uninstall({ stateDir }), /Fully close/)
  assert.deepEqual(fs.readFileSync(asar), patched)
  fs.writeFileSync(asar, original)
  const pending = install({ asar, stateDir })
  assert.equal(pending.status, "prepared")
  assert.equal(pending.running, true)
  assert.deepEqual(fs.readFileSync(asar), original, "running app must not be modified")
  fs.writeFileSync(asar, patched)
  const stopped = new Promise((resolve) => helper.once("exit", resolve))
  helper.kill()
  await stopped
  helper = null

  const state = doctor({ stateDir })
  const backup = fs.readFileSync(state.backup)
  fs.appendFileSync(state.backup, "bad")
  assert.throws(() => uninstall({ stateDir }), /Backup hash mismatch/)
  assert.deepEqual(fs.readFileSync(asar), patched)
  fs.writeFileSync(state.backup, backup)

  const update = fixture("updated build")
  fs.writeFileSync(asar, update)
  assert.throws(() => uninstall({ stateDir }), /different build/)
  assert.deepEqual(fs.readFileSync(asar), update)
  assert.throws(() => doctor({ stateDir }), /probably after an update/)
  assert.equal(install({ asar, stateDir }).status, "healthy")
  assert.equal(uninstall({ stateDir }).status, "restored")
  assert.deepEqual(fs.readFileSync(asar), update, "restore must use this build's exact original")
  assert.equal(uninstall({ stateDir }).status, "restored")

  fs.mkdirSync(path.join(stateDir, ".lock"))
  assert.throws(() => install({ asar, stateDir }), /EEXIST/)
  fs.rmdirSync(path.join(stateDir, ".lock"))

  const broken = Buffer.from(update)
  broken[broken.length - 1] ^= 1
  fs.writeFileSync(asar, broken)
  assert.throws(() => install({ asar, stateDir }), /Invalid archive/)
  assert.deepEqual(fs.readFileSync(asar), broken)
  fs.writeFileSync(asar, update)

  const cli = spawnSync(process.execPath, [path.join(root, "tools/linux.mjs"), "install", "--asar", asar, "--state-dir", stateDir], { encoding: "utf8" })
  assert.equal(cli.status, 0, cli.stderr)
  assert.match(cli.stdout, /healthy/)
  const report = spawnSync(path.join(root, "doctor.sh"), ["--state-dir", stateDir], { encoding: "utf8" })
  assert.equal(report.status, 0, report.stderr)
  assert.match(report.stdout, /Doctor passed/)
  for (const args of [["--prepare-only"], ["--asar", otherAsar], ["--unknown"], ["--state-dir"]]) {
    const invalid = spawnSync(process.execPath, [path.join(root, "tools/linux.mjs"), "uninstall", "--state-dir", stateDir, ...args], { encoding: "utf8" })
    assert.equal(invalid.status, 1, invalid.stderr)
    assert.equal(inspect(asar).patched, true, "invalid arguments must not uninstall")
  }
  const removed = spawnSync(path.join(root, "uninstall.sh"), ["--state-dir", stateDir], { encoding: "utf8" })
  assert.equal(removed.status, 0, removed.stderr)
  assert.deepEqual(fs.readFileSync(asar), update)

  // Optional integration check against an actual installed archive, on a copy.
  if (process.env.T3PT_TEST_ASAR) {
    assert.equal(inspect(process.env.T3PT_TEST_ASAR).patched, false, "T3PT_TEST_ASAR must point to an unpatched archive or original.asar backup")
    const actual = fs.readFileSync(process.env.T3PT_TEST_ASAR)
    fs.writeFileSync(asar, actual)
    assert.equal(install({ asar, stateDir }).status, "healthy")
    assert.equal(uninstall({ stateDir }).status, "restored")
    assert.deepEqual(fs.readFileSync(asar), actual)
  }
  console.log("All Linux installer checks passed.")
} finally {
  helper?.kill()
  fs.rmSync(temp, { recursive: true, force: true })
}
