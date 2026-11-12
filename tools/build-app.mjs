// tools/build-app.mjs — v20.0.46
//
// Builds public/app/index.html (the page the browser loads) from app-src/index.src.html
// (the page we edit). Never edit public/app/index.html by hand: change the source, rebuild,
// commit both.
//
// The source is a complete, working page: its React block (<script type="text/babel"
// data-presets="provly">) is compiled in the browser by Babel-standalone on every visit.
// This build does that compile once, ahead of time, and reproduces what the browser did:
//   - same minimum browsers as the source's "provly" preset (v20.0.28 r1);
//   - JSX → React.createElement / React.Fragment (Babel's classic react preset);
//   - strict mode — Babel-standalone's env preset compiles each block as a module, which
//     prepends "use strict", so the app has always run strict;
//   - the app runs at DOMContentLoaded, the moment Babel-standalone ran it (after the
//     deferred PDF and CSV libraries have loaded).
// It then drops the Babel <script> tag and the preset registration, which nothing else uses.
//
// The output is stamped with the source's sha256 (first 12 hex) and the esbuild version,
// so anyone can check that a committed build matches the committed source.
//
// Run from the repo root (needs esbuild 0.28.2 where Node can find it):
//   npm install -g esbuild@0.28.2
//   NODE_PATH="$(npm root -g)" node tools/build-app.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const esbuild = require("esbuild");

const SRC = "app-src/index.src.html";
const OUT = "public/app/index.html";
const TARGETS = ["chrome79", "edge79", "firefox60", "safari12", "ios12"];
// Where esbuild's browser data is stricter than Babel's (old-Safari bug entries), keep the
// syntax native, exactly as the in-browser Babel compile (env preset, bugfixes: true) has:
//  - destructuring: esbuild marks it unsupported before Safari 14.1 and cannot down-compile
//    it (it would refuse the build); Babel's data has Safari 10+, so it has always run native.
//  - template literals: esbuild rewrites every `${}` to "".concat() for Safari 12; Babel's
//    bugfixes mode keeps them native (its Safari 12 fix is for tagged templates, which the app
//    doesn't use).
const SUPPORTED = { destructuring: true, "template-literal": true };

function fail(msg) {
  console.error("build-app: " + msg);
  process.exit(1);
}

// index of the single occurrence of `needle`, or stop the build
function exactlyOnce(text, needle, what) {
  const i = text.indexOf(needle);
  if (i < 0) fail(`no ${what} found in ${SRC}`);
  if (text.indexOf(needle, i + needle.length) >= 0) fail(`more than one ${what} in ${SRC}`);
  return i;
}

const src = readFileSync(SRC, "utf8");
const srcHash = createHash("sha256").update(src, "utf8").digest("hex").slice(0, 12);

// ── 1. The app block ────────────────────────────────────────────────
const OPEN = '<script type="text/babel" data-presets="provly">';
const CLOSE = "</script>";
const blockStart = exactlyOnce(src, OPEN, "React block");
const blockEnd = src.indexOf(CLOSE, blockStart);
if (blockEnd < 0) fail("the React block has no closing </script>");
const jsx = src.slice(blockStart + OPEN.length, blockEnd);

// ── 2. Compile it ───────────────────────────────────────────────────
let compiled;
try {
  const result = esbuild.transformSync(jsx, {
    loader: "jsx",
    target: TARGETS,
    supported: SUPPORTED,
    jsx: "transform",
    jsxFactory: "React.createElement",
    jsxFragment: "React.Fragment",
    jsxSideEffects: true,     // no /* @__PURE__ */ on each element: nothing here tree-shakes
    charset: "utf8",          // keep ·, —, ’ … as written (no \u escapes)
    legalComments: "none",
    sourcefile: SRC,
    logLevel: "silent",
  });
  for (const w of result.warnings) {
    const at = w.location ? ` (line ${w.location.line + src.slice(0, blockStart).split("\n").length - 1})` : "";
    console.warn("build-app: warning" + at + ": " + w.text);
  }
  compiled = result.code;
} catch (e) {
  const errors = e.errors || [];
  for (const err of errors.slice(0, 20)) {
    const line = err.location ? err.location.line + src.slice(0, blockStart).split("\n").length - 1 : "?";
    console.error(`build-app: ${SRC} line ${line}: ${err.text}`);
  }
  if (errors.length > 20) console.error(`build-app: … and ${errors.length - 20} more`);
  fail("compile failed — nothing written");
}

const appScript =
  '"use strict";\n' +
  "// GENERATED from " + SRC + " by tools/build-app.mjs — edit the source, not this file.\n" +
  "document.addEventListener(\"DOMContentLoaded\", function () {\n" +
  compiled +
  "});\n";

// The compiled code is parsed as an inline <script> by the HTML parser: it must not be able
// to end the element early or switch the parser into its escaped-script states.
if (/<\/script/i.test(appScript)) fail("compiled code contains </script");
if (/<!--/.test(appScript)) fail("compiled code contains <!--");
if (/<script/i.test(appScript)) fail("compiled code contains <script");

// It must be a valid classic script (parsed here, not run).
try {
  new vm.Script(appScript, { filename: OUT });
} catch (e) {
  fail("compiled code does not parse: " + e.message);
}

// ── 3. Assemble the page ────────────────────────────────────────────
let out = src.slice(0, blockStart) + "<script>\n" + appScript + "  " + src.slice(blockEnd);

// the Babel-standalone library tag
const babelTag = out.match(/^[ \t]*<script src="[^"]*babel-standalone[^"]*"><\/script>[ \t]*\n/gm);
if (!babelTag || babelTag.length !== 1) fail("expected exactly one Babel-standalone <script> tag");
out = out.replace(babelTag[0], "");

// the inline script that registers the "provly" preset
const presetAt = exactlyOnce(out, 'Babel.registerPreset("provly"', "preset registration");
const presetOpen = out.lastIndexOf("<script>", presetAt);
const presetClose = out.indexOf(CLOSE, presetAt);
if (presetOpen < 0 || presetClose < 0) fail("could not find the preset registration's <script> element");
let cutStart = out.lastIndexOf("\n", presetOpen) + 1;
let cutEnd = presetClose + CLOSE.length;
if (out[cutEnd] === "\n") cutEnd += 1;
out = out.slice(0, cutStart) + out.slice(cutEnd);

if (/Babel\./.test(out.replace(/<!--[\s\S]*?-->/g, ""))) fail("Babel is still referenced outside comments");
if (/text\/babel/.test(out)) fail("a text/babel block is left");

// the stamp, right after the doctype (a comment before it would put browsers in quirks mode)
const DOCTYPE = "<!DOCTYPE html>\n";
if (!out.startsWith(DOCTYPE)) fail("the source must start with <!DOCTYPE html>");
const stamp =
  `<!-- GENERATED by tools/build-app.mjs (esbuild ${esbuild.version}) from ${SRC} ` +
  `src-sha256 ${srcHash} — edit the source, not this file. -->\n`;
out = DOCTYPE + stamp + out.slice(DOCTYPE.length);

writeFileSync(OUT, out, "utf8");
console.log(`build-app: ${SRC} (${Buffer.byteLength(src)} bytes, src-sha256 ${srcHash})`);
console.log(`build-app: → ${OUT} (${Buffer.byteLength(out)} bytes, esbuild ${esbuild.version})`);
