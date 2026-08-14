# Lumen License and Release Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Lumen under the MIT License and remove obsolete distribution caveats from repository and release copy.

**Architecture:** Keep licensing in one canonical root `LICENSE` file, link it from README and the product website, and synchronize release-facing copy across local notes, the update feed, and GitHub Releases. Preserve packaging verification behavior while removing obsolete explanatory wording.

**Tech Stack:** Markdown, HTML, XML, Bash, Git, GitHub CLI, GitHub Pages

## Global Constraints

- Use the OSI-approved MIT License text with copyright year 2026 and holder `ihopefulChina`.
- Keep the existing 0.0.6 DMG and Sparkle enclosure signature unchanged.
- Do not modify product behavior or version numbers.
- Keep all user-facing license links public and stable.

---

### Task 1: Add and surface the license

**Files:**
- Create: `LICENSE`
- Modify: `README.md`
- Modify: `website/index.html`
- Modify: `scripts/validate-website.sh`

- [ ] Add the canonical MIT License text at the repository root.
- [ ] Replace the old README license notice with a relative link to `LICENSE`.
- [ ] Update the website FAQ and footer with the MIT License status and GitHub license link.
- [ ] Make website validation require the license marker and reject obsolete distribution copy.

### Task 2: Synchronize release copy

**Files:**
- Modify: `appcast.xml`
- Modify: `docs/releases/v0.0.3.md`
- Modify: `docs/releases/v0.0.4.md`
- Modify: `docs/releases/v0.0.5.md`
- Modify: `docs/releases/v0.0.6.md`
- Modify: historical specifications and release checklists containing obsolete copy

- [ ] Remove the obsolete caveats while retaining platform requirements and update-package verification facts.
- [ ] Verify the XML remains well formed and enclosure metadata remains byte-for-byte unchanged.

### Task 3: Verify and publish

**Files:**
- Verify: repository-wide tracked text
- Verify: website output
- Publish: Git commit, GitHub Releases, release appcast asset, GitHub Pages

- [ ] Run the website validator, XML parser, diff checks, and relevant project tests.
- [ ] Confirm the repository contains the standard MIT License text and no obsolete public-facing copy.
- [ ] Commit and push the scoped changes to `main` under the user's standing direct-publish authorization.
- [ ] Update GitHub Release bodies and replace only the `appcast.xml` asset for v0.0.6.
- [ ] Confirm GitHub detects the MIT License and the deployed website shows the updated copy.
