# Lumen 0.0.3 README and Icon Design

## Goal

Replace the current defensive, manual-like README and generic AI-styled icon with a concise product presentation and a distinctive macOS utility icon, then rebuild and publish the verified 0.0.3 release.

## Reference patterns

The design follows the strongest shared patterns in established native Mac projects:

- [Maccy](https://github.com/p0deje/Maccy) opens with a one-sentence purpose, then features, install, usage, advanced details, and FAQ.
- [Ice](https://github.com/jordanbaird/Ice) keeps the product promise and install action near the top, then moves to capability detail.
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) states platform requirements before download and separates user guidance from build instructions.
- [Rectangle](https://github.com/rxhanson/Rectangle) treats the README as a product landing page while keeping development material secondary.

Lumen will copy the information discipline, not their wording or visual identity.

## README direction

The README is Chinese-first and product-first. The first viewport contains the new icon, name, a single direct positioning sentence, the primary screenshot, a download link, and exact platform requirements. It must answer what Lumen is before explaining implementation details.

The content order is:

1. Product identity and download.
2. Main workspace screenshot.
3. Three short value propositions: Finder-like browsing, direct upload/share, and safe native workflows.
4. A three-step start guide.
5. Focused feature groups instead of one flat checklist.
6. A compact shortcut table.
7. Security and distribution facts, including local credential storage, RAM-user guidance, and ACL implications.
8. Honest scope and limits.
9. Source-build instructions.

Tone rules:

- Use calm, concrete sentences; avoid slogans, inflated claims, and defensive comparisons.
- Remove “不是某某套壳” and similar justification.
- Do not describe every setting in the main usage path.
- Keep critical warnings visible but not theatrical.

## Icon direction

The replacement icon is a new mark, not a refinement of the existing red cloud/checkmark image.

- Concept: a luminous folder tray—one clear folder silhouette with a narrow vertical light seam, conveying files, storage, and the name Lumen.
- Shape: a centered macOS rounded-square app tile on a transparent 1024×1024 canvas.
- Palette: restrained deep indigo and cool blue, with an off-white folder mark and a small cyan light accent.
- Rendering: crisp vector-like geometry with subtle material depth and one soft contact shadow; no glossy jelly, glass bloom, bevel overload, or dramatic glow.
- Recognition: the folder outline and light seam must remain legible at 16×16.
- Exclusions: no cloud, checkmark, upload arrow, text, letters, Alibaba logo, mascots, red background, sparkles, or decorative particles.

The generated 1024 px master is inspected before it is resized into all ten macOS AppIcon slots. The asset names use `Icon-v6-*` so the new release cannot reuse stale icon caches.

## Release handling

The existing `v0.0.3` tag points to the pre-branding commit, but no GitHub Release was published. After README/icon verification, the tag is replaced using an exact expected old tag SHA lease, never an unconstrained force push. The DMG is rebuilt from the final commit, its mounted app is checked for 0.0.3 (3), and the release is created with exactly one asset using GitHub CLI.

Publication evidence must include:

- full test result;
- Release build and analyze result;
- DMG mount, version, signature, and launch result;
- SHA-256 before upload and after downloading the public asset;
- GitHub release state: public, non-draft, non-prerelease, latest.

## Acceptance criteria

- README reads like a polished Mac product page and remains technically accurate.
- The icon is clearly distinct from the previous red cloud/checkmark and does not look generically AI-generated.
- Every AppIcon slot references a correctly sized v6 PNG.
- Tests and Release gates pass after the asset change.
- `main`, `v0.0.3`, the release commit, and the public DMG all resolve to the same final product state.
