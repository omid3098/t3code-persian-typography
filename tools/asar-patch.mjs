// Zero-dependency server.asar patcher. It never repacks the archive: the
// original data section is copied byte for byte, new files are appended after
// it and only the JSON header changes, so unpacked native modules and every
// untouched file keep their exact entries.
import { spawnSync } from "node:child_process"
import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

process.noAsar = true

export const CLIENT_DIR = ["apps", "server", "dist", "client"]
export const PAYLOAD_DIR = "t3pt"
export const MARKER_START = "<!-- t3code-persian-typography:start -->"
export const MARKER_END = "<!-- t3code-persian-typography:end -->"
// Renderer anchors runtime.js relies on. They are internal, not a public API.
export const RENDERER_CONTRACTS = [
  "composer-editor",
  "data-user-message-body",
  "data-thread-item",
  "data-timeline-root",
  "--font-sans",
  "--font-composer",
]
const PAYLOAD_FILES = [
  ["runtime.js", "runtime/runtime.js"],
  ["runtime.css", "runtime/runtime.css"],
  ["Vazirmatn.woff2", "fonts/Vazirmatn[wght].woff2"],
]
const BLOCK_SIZE = 4 * 1024 * 1024

function integrity(data) {
  const blocks = []
  for (let offset = 0; offset < data.length; offset += BLOCK_SIZE) {
    blocks.push(crypto.createHash("sha256").update(data.subarray(offset, offset + BLOCK_SIZE)).digest("hex"))
  }
  if (!data.length) blocks.push(crypto.createHash("sha256").update(data).digest("hex"))
  return {
    algorithm: "SHA256",
    hash: crypto.createHash("sha256").update(data).digest("hex"),
    blockSize: BLOCK_SIZE,
    blocks,
  }
}

export function readArchive(file) {
  const fd = fs.openSync(file, "r")
  try {
    const size = fs.fstatSync(fd).size
    const prefix = Buffer.alloc(8)
    fs.readSync(fd, prefix, 0, 8, 0)
    const headerSize = prefix.readUInt32LE(4)
    if (prefix.readUInt32LE(0) !== 4 || headerSize > size - 8) throw new Error(`Not an asar archive: ${file}`)
    const pickle = Buffer.alloc(headerSize)
    fs.readSync(fd, pickle, 0, headerSize, 8)
    const length = pickle.readUInt32LE(4)
    const header = JSON.parse(pickle.subarray(8, 8 + length).toString("utf8"))
    if (!header?.files) throw new Error(`Invalid asar header: ${file}`)
    return { file, header, dataStart: 8 + headerSize, dataLength: size - 8 - headerSize }
  } finally {
    fs.closeSync(fd)
  }
}

function directory(header, segments) {
  let node = header
  for (const segment of segments) {
    node = node.files?.[segment]
    if (!node?.files) throw new Error(`Missing archive directory: ${segments.join("/")}`)
  }
  return node
}

export function readEntry(archive, entry) {
  if (entry.unpacked) throw new Error("Cannot read an unpacked entry from the archive.")
  const data = Buffer.alloc(entry.size)
  const fd = fs.openSync(archive.file, "r")
  try {
    fs.readSync(fd, data, 0, entry.size, archive.dataStart + Number(entry.offset))
  } finally {
    fs.closeSync(fd)
  }
  return data
}

export function injectIndex(index) {
  if (index.includes(MARKER_START)) throw new Error("index.html is already patched.")
  const head = /^([ \t]*)<\/head>/m.exec(index)
  if (!head) throw new Error("Renderer index.html has no closing head tag.")
  const indent = `${head[1]}  `
  const block = [
    MARKER_START,
    '<link rel="stylesheet" href="/t3pt/runtime.css" />',
    '<script defer src="/t3pt/runtime.js"></script>',
    MARKER_END,
  ].map((line) => `${indent}${line}\n`).join("")
  return index.slice(0, head.index) + block + index.slice(head.index)
}

export function missingContracts(archive) {
  const assets = directory(archive.header, [...CLIENT_DIR, "assets"])
  const pending = new Set(RENDERER_CONTRACTS)
  for (const [name, entry] of Object.entries(assets.files)) {
    if (!pending.size) break
    if (entry.files || entry.unpacked || !/\.(?:js|css)$/.test(name)) continue
    const text = readEntry(archive, entry).toString("utf8")
    for (const contract of pending) if (text.includes(contract)) pending.delete(contract)
  }
  return [...pending]
}

export function inspect(file) {
  const archive = readArchive(file)
  const client = directory(archive.header, CLIENT_DIR)
  const index = readEntry(archive, client.files["index.html"]).toString("utf8")
  const payload = client.files[PAYLOAD_DIR]?.files ?? {}
  return {
    patched: index.includes(MARKER_START),
    payload: Object.keys(payload).sort(),
    runtimeVersion: payload["runtime.js"]
      ? /const VERSION = "([^"]+)"/.exec(readEntry(archive, payload["runtime.js"]).toString("utf8"))?.[1] ?? null
      : null,
  }
}

export function patch({ source, output, repoRoot }) {
  const archive = readArchive(source)
  const client = directory(archive.header, CLIENT_DIR)
  if (client.files[PAYLOAD_DIR]) throw new Error("Source archive already contains the typography payload.")
  const missing = missingContracts(archive)
  if (missing.length) {
    throw new Error(`T3 Code renderer changed: missing ${missing.map((m) => `'${m}'`).join(", ")}. Update runtime selectors first.`)
  }

  const header = structuredClone(archive.header)
  const target = directory(header, CLIENT_DIR)
  const blobs = []
  let offset = archive.dataLength
  const append = (entry, data) => {
    entry.size = data.length
    entry.offset = String(offset)
    entry.integrity = integrity(data)
    delete entry.unpacked
    offset += data.length
    blobs.push(data)
  }

  const index = readEntry(archive, client.files["index.html"]).toString("utf8")
  append(target.files["index.html"], Buffer.from(injectIndex(index), "utf8"))
  target.files[PAYLOAD_DIR] = { files: {} }
  for (const [name, relative] of PAYLOAD_FILES) {
    const entry = {}
    target.files[PAYLOAD_DIR].files[name] = entry
    append(entry, fs.readFileSync(path.join(repoRoot, relative)))
  }

  const json = Buffer.from(JSON.stringify(header), "utf8")
  const padded = Math.ceil(json.length / 4) * 4
  const pickle = Buffer.alloc(8 + padded)
  pickle.writeUInt32LE(4 + padded, 0)
  pickle.writeUInt32LE(json.length, 4)
  json.copy(pickle, 8)
  const prefix = Buffer.alloc(8)
  prefix.writeUInt32LE(4, 0)
  prefix.writeUInt32LE(pickle.length, 4)

  const input = fs.openSync(source, "r")
  const out = fs.openSync(output, "w")
  try {
    fs.writeSync(out, prefix)
    fs.writeSync(out, pickle)
    const chunk = Buffer.alloc(BLOCK_SIZE)
    for (let copied = 0; copied < archive.dataLength; ) {
      const read = fs.readSync(input, chunk, 0, Math.min(chunk.length, archive.dataLength - copied), archive.dataStart + copied)
      if (!read) throw new Error("Unexpected end of source archive.")
      fs.writeSync(out, chunk, 0, read)
      copied += read
    }
    for (const blob of blobs) fs.writeSync(out, blob)
  } finally {
    fs.closeSync(input)
    fs.closeSync(out)
  }

  const result = inspect(output)
  if (!result.patched || result.payload.length !== PAYLOAD_FILES.length) {
    throw new Error("Patched archive verification failed.")
  }
  return result
}

const sha256 = (data) => crypto.createHash("sha256").update(data).digest("hex").toUpperCase()

// Checks a snapshot of an archive against its own header: the data section
// ends exactly where the last packed file ends, and every packed file matches
// its recorded SHA-256. A build still being written by the updater fails.
export function verifyArchiveBuffer(data) {
  if (data.length < 16 || data.readUInt32LE(0) !== 4) return "no asar header"
  const headerSize = data.readUInt32LE(4)
  if (headerSize > data.length - 8) return "truncated header"
  const length = data.readUInt32LE(12)
  let header
  try {
    header = JSON.parse(data.subarray(16, 16 + length).toString("utf8"))
  } catch {
    return "unreadable header"
  }
  const dataStart = 8 + headerSize
  let end = 0
  const pending = [header]
  while (pending.length) {
    const node = pending.pop()
    for (const entry of Object.values(node.files ?? {})) {
      if (entry.files) {
        pending.push(entry)
        continue
      }
      if (entry.unpacked || entry.link || entry.size === undefined) continue
      const start = dataStart + Number(entry.offset)
      end = Math.max(end, start + entry.size)
      if (start + entry.size > data.length) return "truncated data"
      if (entry.integrity?.algorithm === "SHA256") {
        const actual = crypto.createHash("sha256").update(data.subarray(start, start + entry.size)).digest("hex")
        if (actual !== entry.integrity.hash) return "file content does not match its header hash"
      }
    }
  }
  if (end !== data.length) return "data length does not match the header"
  return null
}

// Builds a patched server.asar ahead of time, so the watcher can swap it in
// the instant T3 Code's updater exits. The source is read once (Node opens it
// with full sharing, so this never blocks the updater); the watcher later
// checks that server.asar still has sourceSha256 before swapping.
export function prepare({ source, outDir, repoRoot }) {
  fs.mkdirSync(outDir, { recursive: true })
  const original = path.join(outDir, "original.asar")
  const prepared = path.join(outDir, "prepared.asar")
  const meta = path.join(outDir, "prepared.json")
  fs.rmSync(meta, { force: true })

  const data = fs.readFileSync(source)
  const sourceSha256 = sha256(data)
  const incomplete = verifyArchiveBuffer(data)
  if (incomplete) return { incomplete, sourceSha256 }
  fs.writeFileSync(`${original}.tmp`, data)
  fs.renameSync(`${original}.tmp`, original)
  if (inspect(original).patched) {
    fs.rmSync(original, { force: true })
    return { alreadyPatched: true, sourceSha256 }
  }

  const result = patch({ source: original, output: `${prepared}.tmp`, repoRoot })
  fs.renameSync(`${prepared}.tmp`, prepared)
  const info = {
    sourceSha256,
    sourceSize: data.length,
    preparedSha256: sha256(fs.readFileSync(prepared)),
    runtimeVersion: result.runtimeVersion,
  }
  fs.writeFileSync(meta, JSON.stringify(info))
  return info
}

const SEVEN_ZIP_SIGNATURE = Buffer.from([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})

function crc32(data) {
  let crc = 0xffffffff
  for (const byte of data) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

// T3 Code's NSIS installer (electron-builder) stores the app as an embedded
// 7z archive. Finds it by its signature and start-header CRC.
export function findEmbedded7z(file) {
  const fd = fs.openSync(file, "r")
  try {
    const size = fs.fstatSync(fd).size
    const chunk = Buffer.alloc(BLOCK_SIZE + 32)
    for (let position = 0; position < size; position += BLOCK_SIZE) {
      const read = fs.readSync(fd, chunk, 0, chunk.length, position)
      for (let i = chunk.indexOf(SEVEN_ZIP_SIGNATURE); i !== -1 && i < Math.min(read, BLOCK_SIZE); i = chunk.indexOf(SEVEN_ZIP_SIGNATURE, i + 1)) {
        if (i + 32 > read) break
        const header = chunk.subarray(i, i + 32)
        if (header.readUInt32LE(8) !== crc32(header.subarray(12, 32))) continue
        const end = position + i + 32 + Number(header.readBigUInt64LE(12)) + Number(header.readBigUInt64LE(20))
        if (end <= size) return { start: position + i, end }
      }
    }
    return null
  } finally {
    fs.closeSync(fd)
  }
}

// Builds the patched server.asar from a downloaded installer before it runs,
// so once the installer has written that build the watcher only compares one
// hash. Windows' own tar.exe (libarchive) reads the 7z. Node opens the
// installer with full sharing, so this never blocks T3 Code's updater.
export function prepareInstaller({ installer, outDir, repoRoot, tar = path.join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe") }) {
  const range = findEmbedded7z(installer)
  if (!range) throw new Error("The installer has no embedded 7z archive.")
  fs.mkdirSync(outDir, { recursive: true })
  const archive = path.join(outDir, "app.7z")
  const extracted = path.join(outDir, "extract")
  fs.rmSync(extracted, { recursive: true, force: true })
  fs.mkdirSync(extracted)
  try {
    const input = fs.openSync(installer, "r")
    const out = fs.openSync(archive, "w")
    try {
      const chunk = Buffer.alloc(BLOCK_SIZE)
      for (let position = range.start; position < range.end; ) {
        const read = fs.readSync(input, chunk, 0, Math.min(chunk.length, range.end - position), position)
        if (!read) throw new Error("Unexpected end of the installer.")
        fs.writeSync(out, chunk, 0, read)
        position += read
      }
    } finally {
      fs.closeSync(input)
      fs.closeSync(out)
    }
    const result = spawnSync(tar, ["-xf", archive, "-C", extracted, "resources/server.asar"], { encoding: "utf8", windowsHide: true })
    if (result.status !== 0) throw new Error(`tar could not extract server.asar: ${(result.stderr || result.error?.message || "").trim()}`)
    const info = prepare({ source: path.join(extracted, "resources", "server.asar"), outDir, repoRoot })
    if (!info.preparedSha256) throw new Error(`The installer's server.asar is unusable: ${info.incomplete ?? "already patched"}.`)
    return info
  } finally {
    fs.rmSync(archive, { force: true })
    fs.rmSync(extracted, { recursive: true, force: true })
  }
}

function main(argv) {
  const [command, ...rest] = argv
  const options = {}
  for (let i = 0; i < rest.length; i += 2) options[rest[i].replace(/^--/, "")] = rest[i + 1]
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
  if (command === "patch") {
    return patch({ source: options.source, output: options.output, repoRoot })
  }
  if (command === "prepare") {
    return prepare({ source: options.source, outDir: options["out-dir"], repoRoot })
  }
  if (command === "prepare-installer") {
    return prepareInstaller({ installer: options.installer, outDir: options["out-dir"], repoRoot })
  }
  if (command === "inspect") return inspect(options.asar)
  if (command === "contracts") return { missing: missingContracts(readArchive(options.asar)) }
  throw new Error("Usage: asar-patch.mjs patch --source <asar> --output <asar> | prepare --source <asar> --out-dir <dir> | prepare-installer --installer <exe> --out-dir <dir> | inspect --asar <asar> | contracts --asar <asar>")
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(JSON.stringify(main(process.argv.slice(2))))
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
