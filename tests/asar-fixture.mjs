import crypto from "node:crypto"
import fs from "node:fs"

// Minimal ASAR builder shared by patcher and installer tests.
export function writeArchive(file, tree) {
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
