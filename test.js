#!/usr/bin/env bun
// Self-check for the prompt parser: `bun test.js`
import { parseApproval } from "./notify.js";

const claudePrompt = `
│ Bash(rm -rf node_modules)                                    │
│                                                              │
│ Do you want to proceed?                                      │
│ ❯ 1. Yes                                                     │
│   2. Yes, and don't ask again for rm commands in this repo   │
│   3. No, and tell Claude what to do differently (esc)        │
`;

const noPrompt = `
$ ls
README.md notify.js
$
`;

const wrappedLabel = `
 Allow this tool?
 ❯ 1. Yes
   2. No, and tell Claude what to
      do differently
`;

let r = parseApproval(claudePrompt);
console.assert(r, "claude prompt not detected");
console.assert(r.options.length === 3, `expected 3 options, got ${r?.options.length}`);
console.assert(r.options[0].digit === "1" && r.options[0].label === "Yes", JSON.stringify(r.options[0]));
console.assert(r.options[2].digit === "3", JSON.stringify(r.options[2]));
console.assert(r.question === "Do you want to proceed?", JSON.stringify(r.question));

console.assert(parseApproval(noPrompt) === null, "false positive on plain shell");

r = parseApproval(wrappedLabel);
console.assert(r && r.options.length === 2, "wrapped label list not detected");
console.assert(r.question === "Allow this tool?", JSON.stringify(r?.question));

console.log("parse OK");
