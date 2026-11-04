;(function (root) {
  "use strict"

  const VERSION = "1.1.2"
  const FONT_FAMILY = '"T3 Persian"'
  const DEFAULT_SANS = '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif'
  const HAS_RTL_LETTER = /\p{Script=Arabic}/u
  const LTR_LETTERS = /\p{Script=Latin}/u
  const TECHNICAL_TOKEN = /(?:https?:\/\/|www\.)\S+|(?:[A-Za-z]:[\\/]|\.{0,2}[\\/])\S+|\b\S+@\S+\.\S+\b|\b[0-9a-f]{7,}\b/giu
  const EXCLUDED_SELECTOR = [
    "pre",
    "code",
    "kbd",
    "samp",
    "svg",
    "script",
    "style",
    ".katex",
    ".xterm",
    ".chat-markdown-codeblock",
    "[data-thread-terminal-drawer]",
  ].join(", ")
  const COMPOSER_SELECTOR = '[data-testid="composer-editor"]'
  // Prose blocks are managed only inside chat content; elsewhere the UI shell
  // keeps its layout and only Persian labels are isolated.
  const PROSE_SCOPES = [".chat-markdown", "[data-timeline-root]"]
  // List items and table cells get their own direction, line by line. T3 draws
  // an HTML <details> as its own collapsible: a flex button title and a panel.
  const PROSE_TAGS =
    "p, h1, h2, h3, h4, h5, h6, blockquote, ul, ol, li, table, th, td, dt, dd, " +
    "[data-markdown-details-summary], [data-markdown-details-content]"
  const BLOCK_SELECTOR = [
    ...PROSE_SCOPES.map((scope) => `${scope} :is(${PROSE_TAGS})`),
    "[data-user-message-body]",
    COMPOSER_SELECTOR,
  ].join(", ")
  const CONTAINER_SELECTOR = "[data-user-message-body]"
  const NESTED_BLOCK_SELECTOR = "p, ul, ol, h1, h2, h3, h4, h5, h6, blockquote, table, pre"
  const PHRASING_TAGS = new Set([
    "A", "ABBR", "B", "BDI", "BDO", "BR", "CITE", "CODE", "DFN", "EM", "I", "KBD",
    "MARK", "Q", "S", "SAMP", "SMALL", "SPAN", "STRONG", "SUB", "SUP", "TIME", "U", "WBR",
  ])
  const TEXT_INPUT_SELECTOR = 'textarea, input:not([type]), input[type="text"], input[type="search"]'

  function cleanTechnicalText(text) {
    return text.replace(TECHNICAL_TOKEN, " ")
  }

  // Any Persian letter makes the block RTL, however much English it holds.
  function dominantDirection(text) {
    const readable = cleanTechnicalText(text)
    if (HAS_RTL_LETTER.test(readable)) return "rtl"
    return LTR_LETTERS.test(readable) ? "ltr" : null
  }

  // Put the Persian face first; its unicode-range keeps Latin text on the
  // user's own font.
  function withPersianFont(stack) {
    const value = (stack ?? "").trim()
    if (value.startsWith(FONT_FAMILY)) return value
    return `${FONT_FAMILY}, ${value || DEFAULT_SANS}`
  }

  const api = { cleanTechnicalText, dominantDirection, withPersianFont }
  if (typeof module === "object" && module.exports) {
    module.exports = api
    return
  }
  if (!root.document?.documentElement) return

  const document = root.document
  const html = document.documentElement
  if (html.dataset.t3PersianRuntime === VERSION) return

  const originals = new WeakMap()

  function ensureFontStack() {
    for (const name of ["--font-sans", "--font-composer"]) {
      const current = html.style.getPropertyValue(name)
      // An unset composer font already follows --font-sans.
      if (name === "--font-composer" && !current) continue
      const wanted = withPersianFont(current)
      if (current.trim() !== wanted) html.style.setProperty(name, wanted)
    }
  }

  function isExcluded(element) {
    if (element.closest(EXCLUDED_SELECTOR)) return true
    // Leave rich-text editor internals to the editor; only its root is managed.
    const editable = element.closest('[contenteditable="true"]')
    return editable !== null && !element.matches(COMPOSER_SELECTOR)
  }

  function readableText(element) {
    const clone = element.cloneNode(true)
    for (const excluded of clone.querySelectorAll(EXCLUDED_SELECTOR)) excluded.remove()
    return clone.textContent ?? ""
  }

  function remember(element) {
    if (originals.has(element)) return
    originals.set(element, {
      hadDir: element.hasAttribute("dir"),
      dir: element.getAttribute("dir"),
    })
  }

  function restore(element) {
    const original = originals.get(element)
    if (!original) return
    if (original.hadDir) element.setAttribute("dir", original.dir ?? "")
    else element.removeAttribute("dir")
    element.removeAttribute("data-t3pt-direction")
    element.removeAttribute("data-t3pt-label")
    originals.delete(element)
  }

  function setDirection(element, direction, marker = "t3ptDirection") {
    remember(element)
    if (element.getAttribute("dir") !== direction) element.setAttribute("dir", direction)
    if (element.dataset[marker] !== direction) element.dataset[marker] = direction
  }

  function applyBlock(element) {
    if (!element.isConnected || isExcluded(element)) return
    if (!originals.has(element) && element.hasAttribute("dir")) return
    if (element.matches(CONTAINER_SELECTOR) && element.querySelector(NESTED_BLOCK_SELECTOR)) {
      restore(element)
      return
    }

    const direction = dominantDirection(readableText(element))
    if (direction) setDirection(element, direction)
    else if (element.matches(COMPOSER_SELECTOR)) setDirection(element, "auto")
    else restore(element)
  }

  // Short UI text outside prose blocks: thread titles, tabs, menus, dialogs.
  // Only a text-only, non-flex element is managed, so icon rows never flip
  // and the shell keeps its alignment.
  function isLabel(element) {
    if (isExcluded(element) || element.closest(BLOCK_SELECTOR)) return false
    for (const child of element.children) {
      if (!PHRASING_TAGS.has(child.tagName) || child.children.length) return false
    }
    return !/(?:flex|grid)$/.test(root.getComputedStyle(element).display)
  }

  function applyLabel(element) {
    if (!element.isConnected) return
    if (!originals.has(element) && element.hasAttribute("dir")) return
    const text = element.textContent ?? ""
    if (!HAS_RTL_LETTER.test(text) || !isLabel(element)) {
      restore(element)
      return
    }
    setDirection(element, dominantDirection(text) ?? "rtl", "t3ptLabel")
  }

  function applyInput(element) {
    if (!element.hasAttribute("dir")) element.setAttribute("dir", "auto")
  }

  const dirty = new Set()
  let frame = 0

  function collect(element, blocks, labels) {
    let ancestor = element.closest(BLOCK_SELECTOR)
    while (ancestor) {
      blocks.add(ancestor)
      ancestor = ancestor.parentElement?.closest(BLOCK_SELECTOR) ?? null
    }
    for (const block of element.querySelectorAll(BLOCK_SELECTOR)) blocks.add(block)
    for (const input of element.querySelectorAll(TEXT_INPUT_SELECTOR)) applyInput(input)
    if (element.matches(TEXT_INPUT_SELECTOR)) applyInput(element)

    if (originals.has(element)) labels.add(element)
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const parent = node.parentElement
      if (parent && (originals.has(parent) || HAS_RTL_LETTER.test(node.data))) labels.add(parent)
    }
  }

  function flush() {
    frame = 0
    const blocks = new Set()
    const labels = new Set()
    for (const element of dirty) {
      if (element.isConnected) collect(element, blocks, labels)
    }
    dirty.clear()
    for (const block of blocks) applyBlock(block)
    for (const label of labels) {
      if (!blocks.has(label)) applyLabel(label)
    }
  }

  function markDirty(node) {
    const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
    if (element) dirty.add(element)
    if (!frame) frame = requestAnimationFrame(flush)
  }

  html.dataset.t3PersianRuntime = VERSION
  root.__T3PT_STATUS__ = { active: true, version: VERSION }
  ensureFontStack()

  const styleObserver = new MutationObserver(ensureFontStack)
  styleObserver.observe(html, { attributes: true, attributeFilter: ["style"] })

  const observer = new MutationObserver((records) => {
    for (const record of records) {
      markDirty(record.target)
      for (const added of record.addedNodes) markDirty(added)
    }
  })

  function start() {
    markDirty(document.body)
    observer.observe(document.body, {
      characterData: true,
      childList: true,
      subtree: true,
    })
  }

  if (document.body) start()
  else document.addEventListener("DOMContentLoaded", start, { once: true })

  root.addEventListener(
    "pagehide",
    () => {
      observer.disconnect()
      styleObserver.disconnect()
      if (frame) cancelAnimationFrame(frame)
    },
    { once: true },
  )
})(globalThis)
