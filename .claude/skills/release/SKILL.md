---
name: release
description: Cut a Prompt Reply release - ADR, version bump, conventional commit, tag, push. Invoke with the new version, e.g. /release 0.5.0.
disable-model-invocation: true
---

Release version: $ARGUMENTS (ask if empty; current version is the `version` key
in `herdr-plugin.toml`).

Do these in order. The decision log must land before the code, never after.

1. **Verify first.** Run the `verify` skill. Do not release on a red build, and
   if the release contains a notification-behavior change, get the user's
   confirmation on the manual click check before continuing.

2. **Append an ADR to `DECISIONS.md`** — only if this release contains an
   architectural decision (a new dependency, an API/contract change, a reversed
   pattern). A pure bugfix release doesn't need one; say so and skip.

   `DECISIONS.md` is **append-only**. Never edit or reword an existing entry —
   supersede it with a new one. Match the existing format exactly:

   ```markdown
   ## YYYY-MM-DD — Title in sentence case

   **Context:** why this came up.

   **Decision:** what was chosen.

   **Notes / rationale:**
   - the non-obvious parts, and what was rejected.
   ```

   Wrap at the same width as the surrounding entries. Use today's real date.

3. **Bump `version` in `herdr-plugin.toml`.** Also bump `min_herdr_version` if
   the release depends on a newer herdr; otherwise leave it alone.

4. **Commit.** Conventional Commits, `feat!:` if anything user-visible was
   renamed or removed. Include the ADR and the manifest bump in the same commit
   as the code.

5. **Tag and push:**

   ```sh
   git tag v<version>
   git push && git push --tags
   ```

   Confirm the tag with the user before pushing — a pushed tag is what herdr
   installs from.
