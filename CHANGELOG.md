# Changelog

What changed in each release of loomworks (the `lw` command-line tool, the
workspace daemon and its protocol). `lw release-notes` shows these notes
offline, from the release you run; `lw self-update` shows what changed since
your previous version.

<!--
How to write an entry (lua/loomworks/release_notes.lua defines the grammar;
tests/release_notes_spec.lua and scripts/release/release_notes.py check it):

* Every change adds its items under `## Unreleased`, in the section that fits.
* Sections, each at most once per entry, in this order:
  Breaking, Upgrade notes, Added, Changed, Fixed, Security, Removed.
  Breaking and Upgrade notes are what a user must act on; lw shows them even in
  its shortest summaries.
* An item is one `- ` bullet (continuation lines indented by two spaces) that
  says what changed for the user, ending with the PR number: `(#79)`.
* ASCII only; Markdown only for `code spans`.
* Cutting a full release: rename `## Unreleased` to `## <version> - <YYYY-MM-DD>`,
  add a one- or two-sentence summary paragraph under the heading, and put an
  empty `## Unreleased` back on top. The release workflow refuses a full-release
  tag without its entry. Pre-releases have no entry of their own: they ship
  the Unreleased entry.
* A development build takes its version from the newest released entry
  (`<version>+dev`), so the file always keeps at least one.
-->

## Unreleased

### Changed

- `lw`, the workspace daemon and its protocol moved here from loomworks.nvim,
  which is now a client of the daemon. The history of the 0.1.x releases is in
  the CHANGELOG of loomworks.nvim.

### Fixed

- A workspace load still reading its files when the workspace was closed no
  longer replaces the next workspace loaded, or refuses it with the first
  one's error. (#15)
- A change to `loomworks.json`, the working copy or the build cache written
  while a workspace was loading is no longer missed until the file changes
  again. (#16)
- `lw build`, a configure and a launch build refuse a configuration whose
  build directory state is `unknown` (an interrupted delete or reset) instead
  of building in a directory whose contents are untrusted; run `lw clean` or
  `lw reset` first (#20).
- The workspace daemon no longer refuses to delete an orphaned build
  directory by the id its workspace view served, after a request under
  another environment reloaded the workspace. (#105)

## 0.1.49 - 2026-10-19

The last release made from loomworks.nvim. Its notes, and those of every
earlier 0.1.x release, are in the CHANGELOG of loomworks.nvim.

### Added

- `-v` / `--verbose` on `lw build`, `lw run`, `lw test` and `lw clean` prints
  every command a step runs under its header. (#273)
