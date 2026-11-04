import assert from "node:assert/strict"
import crypto from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import {
  CLIENT_DIR,
  MARKER_START,
  RENDERER_CONTRACTS,
  injectIndex,
  inspect,
  missingContracts,
  patch,
  prepare,
  readArchive,
  verifyArchiveBuffer,
  readEntry,
} from "../tools/asar-patch.mjs"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const sha = (data) => crypto.createHash("sha256").update(data).digest("hex").toUpperCase()
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "t3pt-test-"))

// Minimal archive in the same layout as T3 Code's server.asar, including an
// unpacked native entry that must survive untouched.
function writeArchive(file, tree) {
  const blobs = []
  let offset = 0
  const build = (node) => {
    const files = {}
    for (const [name, value] of Object.entries(node)) {
      if (value === "UNPACKED") files[name] = { size: 3, unpacked: true }
      else if (typeof value === "string") {
        const data = Buffer.from(value, "utf8")
        const hash = crypto.createHash("sha256").update(data).digest("hex")
        files[name] = {
          size: data.length,
          offset: String(offset),
          integrity: { algorithm: "SHA256", hash, blockSize: 4194304, blocks: [hash] },
        }
        offset += data.length
        blobs.push(data)
      } else files[name] = build(value)
    }
    return { files }
  }
  const json = Buffer.from(JSON.stringify(build(tree)), "utf8")
  const padded = Math.ceil(json.length / 4) * 4
  const pickle = Buffer.alloc(8 + padded)
  pickle.writeUInt32LE(4 + padded, 0)
  pickle.writeUInt32LE(json.length, 4)
  json.copy(pickle, 8)
  const prefix = Buffer.alloc(8)
  prefix.writeUInt32LE(4, 0)
  prefix.writeUInt32LE(pickle.length, 4)
  fs.writeFileSync(file, Buffer.concat([prefix, pickle, ...blobs]))
}

const index = "<!doctype html>\n<html>\n  <head>\n    <title>T3</title>\n  </head>\n  <body></body>\n</html>\n"
const bundle = RENDERER_CONTRACTS.join(" ")
const tree = {
  "package.json": '{"name":"t3code-server"}',
  node_modules: { native: { "addon.node": "UNPACKED" } },
  apps: { server: { dist: { "bin.mjs": "export {}", client: { "index.html": index, assets: { "index-abc.js": bundle } } } } },
}

try {
  const source = path.join(temp, "server.asar")
  const output = path.join(temp, "patched.asar")
  writeArchive(source, tree)

  assert.deepEqual(missingContracts(readArchive(source)), [])
  assert.equal(inspect(source).patched, false)

  const result = patch({ source, output, repoRoot })
  assert.equal(result.patched, true)
  assert.deepEqual(result.payload, ["Vazirmatn.woff2", "runtime.css", "runtime.js"])
  assert.equal(result.runtimeVersion, JSON.parse(fs.readFileSync(path.join(repoRoot, "package.json"), "utf8")).version)

  const before = readArchive(source)
  const after = readArchive(output)
  assert.deepEqual(after.header.files.node_modules, before.header.files.node_modules, "unpacked entry changed")
  assert.equal(readEntry(after, after.header.files["package.json"]).toString(), tree["package.json"])
  let client = after.header
  for (const segment of CLIENT_DIR) client = client.files[segment]
  assert.equal(readEntry(after, client.files.assets.files["index-abc.js"]).toString(), bundle)
  const patchedIndex = readEntry(after, client.files["index.html"]).toString()
  assert.match(patchedIndex, /\n    <script defer src="\/t3pt\/runtime\.js"><\/script>\n/)
  assert.match(patchedIndex, /typography:end -->\n  <\/head>/)
  assert.deepEqual(
    readEntry(after, client.files.t3pt.files["Vazirmatn.woff2"]),
    fs.readFileSync(path.join(repoRoot, "fonts", "Vazirmatn[wght].woff2")),
  )
  assert.equal(client.files.t3pt.files["runtime.js"].integrity.algorithm, "SHA256")

  // The original data section is copied byte for byte.
  const original = fs.readFileSync(source).subarray(before.dataStart)
  const copied = fs.readFileSync(output).subarray(after.dataStart, after.dataStart + original.length)
  assert.ok(original.equals(copied), "data section was not preserved")

  assert.throws(() => patch({ source: output, output: path.join(temp, "twice.asar"), repoRoot }), /already contains/)
  assert.throws(() => injectIndex(patchedIndex), /already patched/)
  assert.ok(patchedIndex.includes(MARKER_START))

  // A complete build verifies; a build still being written does not.
  const complete = fs.readFileSync(source)
  assert.equal(verifyArchiveBuffer(complete), null)
  assert.equal(verifyArchiveBuffer(fs.readFileSync(output)), null, "the patched build must verify too")
  assert.equal(verifyArchiveBuffer(complete.subarray(0, complete.length - 5)), "truncated data")
  const zeroed = Buffer.from(complete)
  zeroed.fill(0, zeroed.length - 5)
  assert.equal(verifyArchiveBuffer(zeroed), "file content does not match its header hash")
  assert.equal(verifyArchiveBuffer(Buffer.concat([complete, Buffer.alloc(3)])), "data length does not match the header")
  const partial = path.join(temp, "partial.asar")
  fs.writeFileSync(partial, complete.subarray(0, complete.length - 5))
  assert.equal(prepare({ source: partial, outDir: path.join(temp, "partial"), repoRoot }).incomplete, "truncated data")
  assert.equal(fs.existsSync(path.join(temp, "partial", "prepared.json")), false)

  // prepare: a patched build plus an exact copy of the source, ready to swap.
  const prepDir = path.join(temp, "prepared")
  const prepared = prepare({ source, outDir: prepDir, repoRoot })
  assert.equal(prepared.sourceSha256, sha(fs.readFileSync(source)))
  assert.equal(prepared.preparedSha256, sha(fs.readFileSync(path.join(prepDir, "prepared.asar"))))
  assert.ok(fs.readFileSync(path.join(prepDir, "original.asar")).equals(fs.readFileSync(source)))
  assert.equal(inspect(path.join(prepDir, "prepared.asar")).patched, true)
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(prepDir, "prepared.json"), "utf8")), prepared)
  assert.deepEqual(prepare({ source: output, outDir: path.join(temp, "again"), repoRoot }), {
    alreadyPatched: true,
    sourceSha256: sha(fs.readFileSync(output)),
  })

  const broken = path.join(temp, "broken.asar")
  writeArchive(broken, { ...tree, apps: { server: { dist: { client: { "index.html": index, assets: { "index-abc.js": "nothing" } } } } } })
  assert.throws(() => patch({ source: broken, output: path.join(temp, "never.asar"), repoRoot }), /renderer changed: missing/)
  assert.equal(fs.existsSync(path.join(temp, "never.asar")), false)
} finally {
  fs.rmSync(temp, { recursive: true, force: true })
}

console.log("All asar patcher checks passed.")
