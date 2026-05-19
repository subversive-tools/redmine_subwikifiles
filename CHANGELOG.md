# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
