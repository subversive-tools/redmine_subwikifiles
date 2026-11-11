# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

> Contains experimental features that still need clarification and testing — see [doc/OPEN_ISSUES.md](doc/OPEN_ISSUES.md).

### Added
- **Live split preview** in the wiki editor (HedgeDoc-style): "Split" tab between "Edit" and "Preview" shows the editor on the left and a live-rendered Redmine preview on the right (including macros, wiki links and attachments) with a draggable resize handle, synchronized scrolling, remembered preferences, and a plugin setting to toggle the feature. *(to be tested)*
- **Sync status chip** next to "Edit" on wiki pages (in sync / file missing / file changed / wiki changed / conflict / file deleted / folder not writable). *(to be tested)*
- **Sync popover**: scope selector (page · branch · wiki · + subprojects) with live change counts, preview of all actions, inline decisions for conflicts and deleted files, one-click apply. *(to be tested)*
- **Automatic sync in the background** after a wiki page loads: all unambiguous actions in the whole project tree are applied automatically; only uncertain cases (conflict, deleted file, no common base, file without header, attachment) are shown in the chip/popover. *(to be tested)*
- **Deletion list** ("Delete?") in the popover: files of pages deleted in Redmine and pages whose file was deleted. Never automatic, default "skip", per-entry or bulk decision with confirmation. *(to be tested)*
- Throttling of the automatic background sync (once per 60 s per project tree).
- **Three-way sync state** (`SyncState`): direction is derived per page from the last Git commit as common base; only real conflicts need a decision.
- **Experimental:** placeholder parent page (`{{child_pages}}`) is created when an imported file references a parent that exists neither as wiki page nor as file. *(to be clarified/tested)*

### Changed
- Deleting a wiki page no longer deletes its file automatically; files of deleted pages are no longer re-imported automatically.
- Automatic sync on page view only applies unambiguous file changes; conflicts are no longer resolved automatically nor committed.
- The red "Ref-File missing" warning was replaced by the status chip.
- Sync logic extracted from `WikiControllerPatch` into `ProjectSync`.
- Conflict strategy is now respected for page/file comparison; with `db_wins` file modifications no longer overwrite wiki pages.
- New files detected by Git are imported via `WikiImporter` (frontmatter stripped, parent applied).

### Fixed
- Deleting a whole folder (incl. its `.git`) offered to recreate all files instead of asking whether to delete the wiki pages. A registry of known files (`subwikifiles_known_files`, **requires `rake redmine:plugins:migrate`**) now remembers which pages already had a file and where.
- `CookieOverflow` on wiki pages of folders with many unassigned files: messages of the page-view sync were stored in the session cookie; they are now shown for the current request only (`flash.now`), and the "assignment required" notice lists at most 10 files.
- Redesigned "new folder" question: Redmine's own notice/button/link styles (works with every theme), clear labels ("Create project" / "Ignore") with tooltips, inline result instead of `alert()`.
- "Create file from page" showed success even if the file could not be written; now shows the error and path.
- Trailing whitespace in the configured base path broke file creation.
- Files with frontmatter were imported by Git sync with the frontmatter in the page text and without parent.
- Duplicated frontmatter header: Git sync copied modified files *including* the header into the wiki text; the next wiki save then wrapped it in a second header. Git sync now only takes the body, file writes strip any header from the wiki text, and page updates from files save the content reliably.

## [0.5.2] - 2026-05-19

### Changed
- Plugin name: `Redmine Subwikifiles` → `Subwikifiles`.

## [0.5.1] - 2026-05-19

### Fixed
- Created missing `test/test_helper.rb` so all test files can load Redmine's test environment.
- Corrected `require` paths in all four test files (integration and unit tests were pointing one level too deep).
- `FileStorageTest`: added temp-dir setup for `base_path` — tests no longer depend on `/var/lib/redmine/wiki_files` existing.
- `GitBackendTest`: pre-creates `.git` marker so `GitBackend#initialize` skips `init_repo`; rewrote setup to use fixtures and a temp dir.
- `FolderCreationTest`: replaced untestable top-level project creation test with a correct subproject test (the hook only fires for subprojects).
- `ProjectSyncTest`: set `conflict_strategy: db_wins` so rename hooks actually move folders; corrected path expectations to use raw project names instead of underscore-sanitized variants.

## [0.5.0] - 2026-03-13

### Added
- **AJAX folder actions**: inline buttons to create subprojects or ignore new folders — no page reload required.
- **Project inheritance**: new subprojects automatically inherit members, roles, enabled modules, and public status from their parent.
- **Live sidebar updates**: sidebar navigation updates instantly on project creation without a full page reload.
- Top-level project creation from global context.

### Fixed
- Folder detection notice restricted to project-related pages only.
- Live sidebar injection for global (non-project) pages.

## [0.4.0] - 2026-02-16

### Added
- GitHub Actions CI pipeline with integration tests.

## [0.3.0] - 2026-02-16

### Added
- Inline folder detection with create and ignore buttons directly in the wiki page view.

## [0.1.0] - 2026-02-15

### Added
- Initial release.
- Bidirectional sync between Redmine wiki pages and local Markdown files.
- Hierarchical directory structure mirroring wiki page hierarchy.
- Git integration: automatic commits on wiki page save.
- Attachment sync between Redmine and a local `_attachments` folder.
- Conflict detection when file on disk is newer than the database record.
- Orphan file detection and fix buttons.
