# Redmine Subwikifiles -- Technical Documentation

Version: 0.4.0
Date: 2026-02-16

This documentation is intended for developers maintaining or extending the plugin. It covers architecture, data flow, patches, services, and known pitfalls.

---

## Table of Contents

1. [Overview and Architecture](#1-overview-and-architecture)
2. [Initialization and Load Order](#2-initialization-and-load-order)
3. [Filesystem Conventions](#3-filesystem-conventions)
4. [Patches (Model and Controller Level)](#4-patches)
5. [Services](#5-services)
6. [Controller and Routes](#6-controller-and-routes)
7. [UI Integration (ViewHooks)](#7-ui-integration-viewhooks)
8. [Configuration and Permissions](#8-configuration-and-permissions)
9. [Synchronization Flow in Detail](#9-synchronization-flow-in-detail)
10. [Known Pitfalls and Invariants](#10-known-pitfalls-and-invariants)

---

## 1. Overview and Architecture

The plugin provides bidirectional synchronization between Redmine wiki pages and Markdown files on the filesystem. It also manages folder structures (project-to-folder mapping via `.project` metadata) and offers inline UI elements for assigning unassigned files and folders.

### Core Principles

The plugin rests on four pillars:

**Write-Back (Redmine -> Filesystem):** Every wiki change in Redmine is immediately written as an `.md` file with YAML frontmatter and optionally committed via Git.

**Sync-on-Load (Filesystem -> Redmine):** When a wiki page is loaded, the plugin checks whether the file is newer than the DB record. If so, the DB is updated.

**Folder Detection:** Subfolders are scanned at all levels -- both in the base path (top-level) and within existing project directories (potential subprojects). Folders without a `.project` metadata file are considered "unassigned" and can be converted into subprojects or moved to `_orphaned` with a single click.

**File Detection:** Files are scanned in every project directory. Files without an associated wiki page or attachment are considered "unassigned" and can be imported as a wiki page or attached with a single click.

### Component Overview

```
init.rb                              -- Plugin registration, patch loading
lib/redmine_subwikifiles/
  wiki_content_patch.rb              -- before_save / after_find on WikiContent
  wiki_page_patch.rb                 -- before_save / after_save / before_destroy on WikiPage
  wiki_controller_patch.rb           -- before_action on WikiController (sync + consistency)
  project_patch.rb                   -- after_save on Project (folder renaming)
  file_storage.rb                    -- Path resolution, reading/writing files
  folder_scanner.rb                  -- Detection of unassigned folders
  file_scanner.rb                    -- Detection of unassigned files (orphans)
  wiki_importer.rb                   -- Import of files as wiki pages
  frontmatter_parser.rb              -- YAML frontmatter parsing/building
  frontmatter_fixer.rb               -- Adding empty frontmatter blocks
  git_backend.rb                     -- Git operations (commit, rename, delete, detect)
  git_sync.rb                        -- Orchestration of Git changes -> Redmine
  attachment_handler.rb              -- Attachment sync (FS <-> Redmine)
  file_lock_checker.rb               -- Checking whether a file is locked externally
  view_hooks.rb                      -- JS/CSS injection for fix and folder buttons
  hooks.rb                           -- Redmine hooks (project creation, UI elements)
app/controllers/
  subwikifiles_controller.rb         -- AJAX endpoints (fix, attach, create subproject, orphan)
  subwikifiles_settings_controller.rb -- Settings management
```

---

## 2. Initialization and Load Order

Defined in `init.rb`. The order matters because later patches depend on previously loaded services.

**Step 1 -- Load core services:**
`FrontmatterParser`, `FileStorage`, `FileLockChecker`, `FrontmatterFixer`, `FileScanner`, `WikiImporter`

**Step 2 -- Load ViewHooks:**
`ViewHooks` (injects JS/CSS into Redmine layouts)

**Step 3 -- Apply model patches:**
`WikiContentPatch` -> `WikiContent`, `WikiPagePatch` -> `WikiPage`

**Step 4 -- Apply controller patches:**
`WikiControllerPatch` -> `WikiController`, `ProjectPatch` -> `Project`

All patches are applied directly via `send(:include, ...)`. Errors during loading are caught and logged but do not abort initialization.

Note: In Redmine development mode with auto-reloading, patches may be lost after class reloading. For development, `config.eager_load = true` or a `to_prepare` block is recommended (not currently implemented).

---

## 3. Filesystem Conventions

### Directory Structure

```
{base_path}/
  {project_folder}/                 -- Folder name is freely choosable (via .project)
    .project                        -- YAML metadata: id, name, created
    .git/                           -- Git repository (per project)
    Wiki_Page.md                    -- Wiki page with frontmatter
    Another Page.md                 -- Spaces in filenames are allowed
    _attachments/                   -- Attachment sync folder
      Page_Title/
        image.png
    _orphaned/                      -- Ignored folders
    {subfolder}/                    -- Potential subprojects
      .project
      ...
```

### .project Metadata File

Every assigned project folder contains a `.project` file in YAML frontmatter format:

```yaml
---
id: project-identifier
name: "Displayed Project Name"
created: "2026-02-15T12:00:00+01:00"
---
```

The `id` field is the Redmine project identifier and is used for mapping. The folder name itself is freely choosable and may contain spaces, uppercase letters, etc.

### Wiki File Frontmatter

Every `.md` file begins with a YAML block:

```yaml
---
parent: Parent Page
id: 42
created: '2026-02-15T12:00:00+01:00'
updated: '2026-02-15T12:00:00+01:00'
---

Actual wiki content here...
```

Frontmatter fields:
- `parent` -- Title of the parent wiki page (for hierarchy)
- `id` -- Redmine WikiPage ID (for robust rename detection during import)
- `created` -- Creation timestamp (ISO 8601)
- `updated` -- Last modification timestamp (ISO 8601)

### Filenames and Title Normalization

The mapping between filename and wiki title is non-trivial. `FileStorage#resolve_existing_path` tries multiple variants:
1. `sanitize_filename(title)` -- Spaces replaced by underscores, special characters removed
2. Title as-is (e.g. with spaces)
3. Hyphens instead of spaces
4. Minimal sanitization
5. Lowercase variants

The `FileScanner` additionally uses `Wiki.titleize` for matching against Redmine titles. This normalization is a frequent source of bugs (see section 10).

### Reserved Folder Names

The following folder names are skipped during scanning:
- Anything with a leading dot (`.git`, `.project`, etc.)
- `_orphaned` -- Ignored folders
- `_attachments` -- Attachment directory

---

## 4. Patches

### 4.1 WikiContentPatch (`wiki_content_patch.rb`)

Patches the `WikiContent` model with two callbacks:

**`before_save :write_to_md_file_with_frontmatter`**
Called on every wiki save. Builds frontmatter metadata (parent, id, created, updated), combines it with page content via `FrontmatterParser.build`, writes the result via `FileStorage#write`, syncs attachments via `AttachmentHandler#sync_to_fs`, and creates a Git commit via `GitBackend#commit`.

**`after_find :load_from_md_file_with_frontmatter`**
Called when a WikiContent object is loaded. Reads the associated file and compares timestamps. If the file is newer and the `conflict_strategy` allows it (`file_wins` or `manual`), the DB content is updated. The Git author is extracted from the last commit and noted in the version comment. Additionally, the parent relationship is synchronized from the frontmatter.

**Loop prevention:** Both callbacks check `Thread.current[:redmine_subwikifiles_syncing]`. If the flag is set, the callback is skipped.

**Plugin check:** `plugin_enabled?` checks both the global setting and project-specific module activation (including ancestor projects).

### 4.2 WikiPagePatch (`wiki_page_patch.rb`)

Patches the `WikiPage` model:

**`before_save :handle_title_change`** -- On title change, the file on the FS is renamed and a Git rename is executed.

**`after_save :update_frontmatter_on_parent_change`** -- On parent relationship change, the content is re-saved so that the frontmatter is updated.

**`before_destroy :delete_file`** -- Deletes the associated file and executes a Git delete.

### 4.3 WikiControllerPatch (`wiki_controller_patch.rb`)

Patches `WikiController` with two `before_action` callbacks for the actions `index`, `show`, `edit`:

**`sync_from_filesystem`** -- The central sync entry point. Flow:
1. Load project and check permissions (`edit_wiki_pages`)
2. Call `GitSync#sync_from_filesystem` (detect and process staged changes)
3. Call `sync_folder_renames_to_redmine` (folder renames -> project name, only for `file_wins`/`manual`)
4. Call `FileScanner#scan_for_new_files` (orphan detection)
5. Auto-import files with valid frontmatter via `WikiImporter`
6. Display remaining orphans as a flash warning with interactive buttons
7. Provide `@pending_files_json` for ViewHooks

**`check_file_consistency`** -- Checks for a single wiki page:
- Does the file exist? If not: show restore link
- Is the file locked (in edit mode)? If so: show warning
- Does the content match? If not: auto-update with Git author

### 4.4 ProjectPatch (`project_patch.rb`)

Patches the `Project` model with two `after_save` callbacks:

**`rename_subwikifiles_folder_on_identifier_change`** -- Reacts to identifier changes.

**`rename_subwikifiles_folder_on_name_change`** -- Reacts to name changes.

Both delegate to `perform_rename`, which behaves depending on the `conflict_strategy`:
- `file_wins`: Folder is NOT renamed, only `.project` metadata is updated
- `db_wins` / `manual`: Folder is renamed, `.project` is updated

The folder search uses `scan_for_project_folder`, which searches `.project` files by identifier. Case-only renames on case-insensitive filesystems are handled correctly via `File.realpath` comparison.

**Loop prevention:** Checks `Thread.current[:redmine_subwikifiles_syncing]` and ignores its own sync changes.

---

## 5. Services

### 5.1 FileStorage (`file_storage.rb`)

Central class for all filesystem operations of a project.

**Path resolution (`build_project_path`):** Searches recursively (for nested projects) for the correct folder. Priority:
1. Folder with a `.project` file whose `id` matches the project identifier
2. Folder with the raw project name
3. Folder with sanitized project name (legacy)
4. Fallback: raw name as default for new folders

**Key methods:**
- `read(title)` -> `[content, mtime]` or `nil`
- `write(title, content)` -- Writes file, creates directory if needed
- `file_path(title)` -- Returns the default path for a new file (sanitized)
- `resolve_existing_path(title)` (private) -- Tries multiple filename variants
- `self.write_project_metadata(folder_path, project)` -- Writes `.project` file
- `self.sanitize_filename(title)` -- Spaces -> underscores, only `\w` and `-`

### 5.2 FolderScanner (`folder_scanner.rb`)

Scans a directory for subfolders without a `.project` metadata file.

Can be used globally (without project, scans `base_path`) or project-specifically (scans `project_path`). Skips hidden folders, `.md` files, and reserved names (`_orphaned`, `_attachments`).

Returns an array of hashes with `path`, `name`, `parent_project`, etc.

### 5.3 FileScanner (`file_scanner.rb`)

Scans the project directory for files without an associated wiki page or attachment.

For `.md` files: compares via `Wiki.titleize` against existing wiki titles, checks frontmatter validity. For other files: checks whether already registered as an attachment. Locked files (via `FileLockChecker`) are reported separately.

### 5.4 WikiImporter (`wiki_importer.rb`)

Creates or updates wiki pages from filesystem data.

**Rename detection:** Searches for existing pages via the `id` field in the frontmatter. If the ID matches but the title differs, the page is renamed.

**Parent assignment:** Sets the parent relationship according to frontmatter. Fails if the referenced parent page does not exist.

**Cleanup:** After successful import, the original file is deleted if the normalized path differs (prevents endless re-detection).

### 5.5 FrontmatterParser (`frontmatter_parser.rb`)

Static utility class for YAML frontmatter operations:
- `parse(text)` -> `{ metadata: Hash, content: String }`
- `build(metadata, content)` -> String with frontmatter
- `update_metadata(text, new_metadata)` -> Text with merged frontmatter
- `get_metadata(text, key)` -> Single value
- `strip_frontmatter(text)` -> Content only

Recognizes the format `---\n...\n---\n` at the beginning of the file. On parse errors, the raw text is returned.

### 5.6 FrontmatterFixer (`frontmatter_fixer.rb`)

Adds an empty frontmatter block (`---\n---\n\n`) to the beginning of files that lack one. Checks for lock and existing frontmatter first.

### 5.7 GitBackend (`git_backend.rb`)

Encapsulates Git operations per project.

**Initialization:** Uses `FileStorage` for path resolution. Initializes a new Git repo if none exists (including local user config).

**Methods:**
- `commit(title, author:, message:)` -- `git add` + `git commit` with author mapping
- `rename(old, new, author:, message:)` -- `git mv` + commit
- `delete(title, author:, message:)` -- `git rm` + commit
- `detect_changes` -> Hash with `:renamed`, `:deleted`, `:modified`, `:added`
- `last_commit_author(file_path)` -> String (author name) or nil
- `run_git(*args)` -- Public, also used by `GitSync`

Warning: Filename sanitization in `GitBackend` (`gsub(' ', '_').gsub(/[^\w\/\-]/, '')`) is implemented independently from `FileStorage.sanitize_filename`. When changing sanitization logic, both locations must be updated.

### 5.8 GitSync (`git_sync.rb`)

Orchestrates the transfer of Git changes into the Redmine database.

**Flow of `sync_from_filesystem`:**
1. `git add -A` (stage all changes so that renames can be detected)
2. `detect_changes` via GitBackend
3. Process changes in order: Deleted -> Renamed -> Modified -> Added
4. Final commit

**Important:** Deleted files do NOT lead to deletion of the wiki page (`delete_page_in_redmine` is commented out). The active check in `check_file_consistency` shows a restore link instead.

New files are only created as wiki pages if they have valid frontmatter.

### 5.9 AttachmentHandler (`attachment_handler.rb`)

Synchronizes attachments of a wiki page between Redmine and the filesystem.

**`sync_to_fs`:** Copies Redmine attachments to `{project_path}/_attachments/{sanitized_title}/`.

**`sync_from_fs`:** Reads files from the attachment directory and creates Redmine attachments for files not yet registered.

Note: Uses `project.identifier` for the path, not `FileStorage.project_path`. For projects with a differing folder name, the path may be incorrect.

### 5.10 FileLockChecker (`file_lock_checker.rb`)

Checks via `flock(LOCK_EX | LOCK_NB)` whether a file is locked by an external process. Used by `FileScanner` and `check_file_consistency`.

---

## 6. Controller and Routes

### SubwikifilesController (`subwikifiles_controller.rb`)

Provides AJAX endpoints and regular actions:

| Route | Method | Action | Purpose |
|---|---|---|---|
| `GET subwikifiles/folder_prompt` | GET | `folder_prompt` | Show unassigned folders (global) |
| `POST subwikifiles/assign_folder` | POST | `assign_folder` | Assign folder (global) |
| `GET projects/:id/subwikifiles/folder_prompt` | GET | `folder_prompt` | Show unassigned folders (project) |
| `POST projects/:id/subwikifiles/assign_folder` | POST | `assign_folder` | Assign folder (project) |
| `POST projects/:id/subwikifiles/fix_frontmatter` | POST | `fix_frontmatter` | Import orphan files as wiki pages (AJAX) |
| `POST projects/:id/subwikifiles/attach_file` | POST | `attach_file` | Attach file as attachment (AJAX) |
| `POST projects/:id/subwikifiles/restore_file` | POST | `restore_file` | Restore missing file from wiki content |
| `POST projects/:id/subwikifiles/create_subproject_from_folder` | POST | `create_subproject_from_folder` | Create subproject from folder (AJAX) |
| `POST projects/:id/subwikifiles/orphan_folder` | POST | `orphan_folder` | Move folder to `_orphaned` (AJAX) |

**Subproject creation (`do_create_subproject`):** Generates identifier from folder name (lowercase, special characters replaced by hyphens), ensures uniqueness, creates project with `parent`, enables modules `wiki` and `redmine_subwikifiles`, writes `.project` metadata, and initializes Git repo.

**Orphan move (`do_orphan_folder`):** Moves the folder to `{project_path}/_orphaned/`, with a timestamp suffix on name collision.

---

## 7. UI Integration (ViewHooks)

### ViewHooks (`view_hooks.rb`)

Injects JavaScript and CSS into `view_layouts_base_html_head`. Two main blocks:

**`build_js` -- Orphan file buttons:**
Only runs on wiki pages (`WikiController`, actions `index`/`show`/`edit`). Reads `@pending_files_json` and creates green checkmark buttons next to each orphan file in the flash warning. Buttons send AJAX requests to `fix_frontmatter` or `attach_file`. In edit mode, a wiki link or image tag is inserted at the cursor position after successful import.

**`build_folder_js` -- Unassigned folder buttons:**
Runs on project pages and the global project list. Scans via `FolderScanner` for unassigned folders. On `/projects/`, folders are injected inline into the project table or board view. On other pages, they are displayed as a flash notice. Each folder gets two buttons: green checkmark (create subproject) and grey X (move to `_orphaned`).

### Hooks (`hooks.rb`)

**`view_projects_form`:** Hides the module checkbox in project settings when the plugin is globally enabled (via CSS `:has` selector).

**`controller_projects_new_after_save`:** Automatically creates a folder with `.project` metadata when a new subproject is created (provided no matching folder already exists).

---

## 8. Configuration and Permissions

### Plugin Settings (`config/settings.yml`)

| Key | Default | Description |
|---|---|---|
| `base_path` | `/var/lib/redmine/wiki_files` | Absolute path for wiki files |
| `enabled` | `false` | Global activation (otherwise per project via module) |
| `git_enabled` | `true` | Git integration active |
| `conflict_strategy` | `file_wins` | Conflict resolution: `file_wins`, `db_wins`, `manual` |

### Conflict Strategies in Detail

**`file_wins`:** Filesystem is authoritative. When the file is newer, the DB is overwritten. Folder renames on the FS are synchronized to the project name in Redmine. Renames in Redmine only update `.project` metadata, not the folder name.

**`db_wins`:** Database is authoritative. Changes on the FS are ignored. Project renames in Redmine lead to folder renames. Folder renames on the FS are not synchronized to Redmine.

**`manual`:** Bidirectional. Currently behaves similarly to `file_wins` for the sync direction FS->DB. Project renames in Redmine lead to folder renames on the FS.

### Permissions

The plugin defines a project module `redmine_subwikifiles` with one permission:
- `:manage_subwikifiles` -- Authorizes folder management (folder_prompt, assign_folder, fix_frontmatter, attach_file). Requires project membership.

Additionally, the existing Redmine permission `:edit_wiki_pages` is used for synchronization and consistency checks.

Admins bypass all permission checks.

---

## 9. Synchronization Flow in Detail

### Scenario: User opens a wiki page (`show`)

```
WikiController#show
  |
  +-- before_action: sync_from_filesystem
  |     |
  |     +-- GitSync#sync_from_filesystem
  |     |     +-- git add -A
  |     |     +-- detect_changes (git status --porcelain)
  |     |     +-- Process renamed/modified/added
  |     |
  |     +-- sync_folder_renames_to_redmine (only file_wins/manual)
  |     |     +-- For project + direct children: folder name != project name?
  |     |     +-- If so: Project.name = folder name
  |     |
  |     +-- FileScanner#scan_for_new_files
  |     |     +-- Orphans with frontmatter -> WikiImporter (auto)
  |     |     +-- Orphans without frontmatter -> Flash warning + @pending_files_json
  |     |
  |     +-- @page.reload
  |
  +-- before_action: check_file_consistency
  |     +-- File exists? -> Compare content -> auto-update if needed
  |     +-- File missing? -> Show restore link
  |
  +-- WikiContent#after_find (load_from_md_file_with_frontmatter)
  |     +-- File newer than DB? -> Update DB (conflict_strategy)
  |
  +-- ViewHooks: Inject JS for orphan buttons and folder buttons
```

### Scenario: User saves a wiki page

```
WikiContent#before_save (write_to_md_file_with_frontmatter)
  |
  +-- Build frontmatter (parent, id, created, updated)
  +-- FrontmatterParser.build(metadata, text)
  +-- FileStorage#write(title, full_content)
  +-- AttachmentHandler#sync_to_fs
  +-- GitBackend#commit(title, author, message)
```

### Scenario: File is edited externally

On the next page load, the change is detected via:
1. `GitSync#sync_from_filesystem` (if git-tracked)
2. `check_file_consistency` (timestamp comparison)
3. `WikiContent#after_find` (timestamp comparison)

There are thus multiple layers that can detect the change. The first successful update sets `Thread.current[:redmine_subwikifiles_syncing]`, so subsequent layers do not write again.

---

## 10. Known Pitfalls and Invariants

### Title Normalization (critical)

Redmine normalizes wiki titles internally (`Wiki.titleize`). Every search for files or pages MUST normalize consistently. Deviations lead to duplicates or endless re-detection as orphans. There are currently three independent sanitization implementations: `FileStorage.sanitize_filename`, the variant search in `resolve_existing_path`, and the sanitization in `GitBackend`. When making changes, all three locations must be considered.

### Loop Prevention (critical)

Without `Thread.current[:redmine_subwikifiles_syncing]`, an infinite loop occurs: file change -> DB update -> before_save -> file write -> change detected -> DB update -> ...

Every automated change MUST set this flag and reset it in the `ensure` block. This also applies to `ProjectPatch` (prevents ping-pong during folder renames).

### AttachmentHandler Path Inconsistency

`AttachmentHandler` constructs the path manually via `project.identifier`, while all other classes use `FileStorage.project_path`. For projects with a differing folder name (via `.project`), the attachment path may be incorrect.

### Git Sanitization vs. FileStorage Sanitization

`GitBackend` sanitizes filenames independently from `FileStorage`. If a file with spaces in the name is created (which `FileStorage` supports), `GitBackend` may reference the wrong file.

### Multiple Sync Checks per Request

A single page load can read and compare the file up to three times (GitSync, check_file_consistency, after_find). This is redundant but usually harmless due to the thread flags. Performance optimization would be possible through a central sync check per request.

### FileScanner vs. GitSync Overlap

Both `GitSync` (via `git status`) and `FileScanner` (via directory scan) detect new files. `GitSync` only creates pages for files with frontmatter, while `FileScanner` reports all unassigned files. The order in `sync_from_filesystem` ensures that `GitSync` runs first and `FileScanner` only finds the remaining orphans.

### Case Sensitivity

For folder renaming via `ProjectPatch`, case-insensitive filesystems (macOS HFS+/APFS) are explicitly handled via `File.realpath` comparison. For filenames in `FileStorage`, this handling does not exist.

### Missing Error Handling for Git

Git operations are consistently wrapped in `rescue` blocks. Errors are logged but do not block wiki operations. This means: with Git problems (e.g. lock conflicts, corrupt repo), the wiki continues to work, but versioning may be inconsistent.

### No Permission Sync to Filesystem

Redmine permissions (e.g. read/write access to a project) are NOT propagated to the filesystem. The folders and files on the disk do not inherit the access rights of the Redmine project. Access control relies solely on the OS-level permissions of the user running Redmine. **This is a potential future feature.**
