# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
