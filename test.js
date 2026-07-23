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

const boxedPrompt = `
✻ Baked for 9s
────────────────────────────────────────
 Bash command
   rtk git stash push -q -- src/services/fetch.ts && npx vue-tsc --noEmit
   Test removing fetch.ts AbortSignal
 This command requires approval
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for git checkout, rtk npx, and echo commands in /Users/tung/Projects
   3. No
 Esc to cancel · Tab to amend · ctrl+e to explain
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

r = parseApproval(boxedPrompt);
console.assert(r && r.options.length === 3, "boxed prompt not detected");
console.assert(r.context[0] === "Bash command", JSON.stringify(r?.context));
console.assert(r.context.some((l) => l.includes("rtk git stash push")), "command line missing from context");
console.assert(!r.context.some((l) => l.includes("Baked")), "context leaked past the rule");
console.assert(r.question === "Do you want to proceed?", JSON.stringify(r?.question));

const longCommand = `
✻ Baked for 3m 2s
 Bash command
   git commit -m "$(cat <<'EOF'
   refactor: strip unrelated changes
   line3
   line4
   line5
   line6
   EOF
   Commit product-picker removal
 This command requires approval
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again
   3. No
`;

r = parseApproval(longCommand);
console.assert(r && r.options.length === 3, "long command prompt not detected");
console.assert(r.context[0] === "Bash command", JSON.stringify(r?.context[0]));
console.assert(r.context.includes("…"), "long context not compressed");
console.assert(r.context.at(-1) === "Do you want to proceed?", JSON.stringify(r?.context.at(-1)));
console.assert(!r.context.some((l) => l.includes("Baked")), "context leaked past status line");
console.assert(r.context.length === 7, `expected 7 lines, got ${r?.context.length}`);

console.log("parse OK");
