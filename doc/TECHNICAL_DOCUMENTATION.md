# Redmine Subwikifiles — Technical Documentation

Version: 0.6.0-dev
Date: 2026-11-11

This documentation is intended for developers maintaining or extending the plugin. It covers architecture, 3-way synchronization, data flow, patches, services, UI hooks, and known invariants.

---

## Table of Contents

1. [Overview and Architecture](#1-overview-and-architecture)
2. [Initialization and Load Order](#2-initialization-and-load-order)
3. [Filesystem & Database Conventions](#3-filesystem--database-conventions)
4. [Patches (Model and Controller Level)](#4-patches-model-and-controller-level)
5. [Services](#5-services)
6. [Controller and Routes](#6-controller-and-routes)
7. [UI Integration (SyncUiHooks & ViewHooks)](#7-ui-integration-syncuihooks--viewhooks)
8. [Configuration and Permissions](#8-configuration-and-permissions)
9. [Synchronization Flow in Detail](#9-synchronization-flow-in-detail)
10. [Known Pitfalls and Invariants](#10-known-pitfalls-and-invariants)

---

## 1. Overview and Architecture

The plugin provides bidirectional synchronization between Redmine wiki pages and Markdown files on the filesystem, manages folder structures (project-to-folder mapping via `.project` metadata), offers a 4-scope sync status chip & popover, and adds a HedgeDoc-style live split preview to the wiki editor.

### Core Principles

1. **Write-Back (`Redmine → Filesystem`):** Every wiki save in Redmine writes an `.md` file with YAML frontmatter, remembers the file in the `subwikifiles_known_files` registry, syncs attachments, and commits to the project's local Git repository.
2. **Three-Way State Classification (`SyncState`):** Compares the wiki text, the file body on disk, and the last committed version (`HEAD`) in the project's Git repository as common base (`:ok`, `:create_file`, `:deleted`, `:to_wiki`, `:to_file`, `:conflict`).
3. **Automatic Background Sync & Interactive Popover (`SyncPlan`):** Unambiguous actions (`create_file`, `to_file`, `to_wiki` unless `db_wins`, `import` with frontmatter) are applied automatically in the background (throttled to once per 60 s per project tree). Uncertain cases (conflicts, deletions, files without frontmatter, attachments, no common base) are highlighted in the status chip and decided interactively in the popover.
4. **Never Automate Deletions:** Deleting a wiki page keeps the file on disk; deleting a file (or whole folder) keeps the wiki page. Both are listed in a dedicated **"Delete?"** section in the sync popover (`default: 'skip'`).
5. **Folder & File Detection:** Unassigned folders without `.project` metadata can be turned into projects/subprojects or moved to `_orphaned`. Unassigned files without frontmatter or attachments can be imported/attached with one click.

### Component Overview

```text
init.rb                                     -- Plugin registration, settings helpers, throttling, patch loading
db/migrate/
  001_create_subwikifiles_known_files.rb    -- Registry of known page->file mappings (survives folder deletion)
lib/redmine_subwikifiles/
  frontmatter_parser.rb                     -- YAML frontmatter parsing and building
  file_storage.rb                           -- Path resolution, reading/writing .md and .project files
  file_lock_checker.rb                      -- Non-blocking flock check for external editors
  file_scanner.rb                           -- Detection of unassigned .md and attachment files
  folder_scanner.rb                         -- Detection of unassigned folders
  wiki_importer.rb                          -- Import of files as wiki pages (incl. rename & parent handling)
  attachment_importer.rb                    -- Shared service to attach a file and move it to _attachments
  attachment_handler.rb                     -- Page attachment sync (FS <-> Redmine)
  git_backend.rb                            -- Per-project Git operations (init, commit, rename, delete, status)
  git_sync.rb                               -- Applies unambiguous Git changes from filesystem to Redmine
  project_sync.rb                           -- Project- and page-level sync orchestration
  known_file.rb                             -- ActiveRecord model for subwikifiles_known_files
  sync_state.rb                             -- Three-way sync state classification against Git HEAD
  sync_plan.rb                              -- Dry-run plan builder and executor across 4 scopes
  sync_ui_hooks.rb                          -- ViewListener for sync status chip/popover & live split preview
  view_hooks.rb                             -- ViewListener for orphan file buttons, folder prompt & path info
  hooks.rb                                  -- Project form & subproject folder creation hooks
  wiki_content_patch.rb                     -- before_save / after_find on WikiContent
  wiki_page_patch.rb                        -- before_save / after_save / before_destroy on WikiPage
  wiki_controller_patch.rb                  -- before_action on WikiController (sync + consistency)
  project_patch.rb                          -- after_save on Project (folder renaming)
app/controllers/
  subwikifiles_controller.rb                -- Endpoints: plan, auto, apply, folder/orphan actions
app/assets/
  javascripts/subwikifiles_sync.js          -- Status chip, background auto-sync & 4-scope popover UI
  javascripts/subwikifiles_live_preview.js  -- HedgeDoc-style live split preview in the wiki editor
  stylesheets/subwikifiles_sync.css         -- Theme-agnostic styles for status chip & popover
  stylesheets/subwikifiles_live_preview.css -- Split editor layout & draggable divider styles
```

---

## 2. Initialization and Load Order

Defined in `init.rb`:

- **`RedmineSubwikifiles` module helpers:**
  - `base_path`: Configured base directory with surrounding whitespace stripped.
  - `conflict_strategy`: `'file_wins'` (default), `'db_wins'`, or `'manual'`.
  - `enabled_for?(project)`: Checks global activation or module activation on `project.self_and_ancestors`.
  - `live_preview_enabled?`: Checks whether the live split preview is enabled (default: `true`).
  - `throttle_slot?(key, interval)`: Reserves a throttle slot (60 s default) via `Rails.cache` or an in-process mutex map when `NullStore` is active.
  - `without_auto_sync { ... }`: Temporarily sets `Thread.current[:redmine_subwikifiles_syncing] = true` to suppress recursive callbacks.

---

## 3. Filesystem & Database Conventions

### Directory Structure

```text
{base_path}/
  {project_folder}/                 -- Folder name matches project name (mapped via .project)
    .project                        -- YAML metadata: id, name, created
    .git/                           -- Git repository (per project)
    Wiki_Page.md                    -- Wiki page with YAML frontmatter
    _attachments/                   -- Attachment sync folder
      Page_Title/
        image.png
    _orphaned/                      -- Ignored folders
    {subfolder}/                    -- Subprojects
      .project
      .git/
      ...
```

### Known Files Registry (`subwikifiles_known_files`)

When a single `.md` file is deleted on disk, the project folder's `.git` history still knows the file existed. However, when a user deletes an **entire project folder** on disk, `.git` is deleted with it. The database table `subwikifiles_known_files` (`KnownFile`: `page_id`, `project_id`, `path`, `synced_at`) persists in Redmine's database so `SyncState` reliably classifies pages of a deleted folder as `:deleted` (asking whether to delete the wiki pages or restore the files) rather than `:create_file`.

---

## 4. Patches (Model and Controller Level)

### 4.1 `WikiContentPatch` (`wiki_content_patch.rb`)
- **`before_save :write_to_md_file_with_frontmatter`**: Strips any accidental frontmatter from the wiki text (`text_without_frontmatter`), builds fresh YAML metadata (`parent`, `id`, `created`, `updated`), writes the `.md` file, records it in `KnownFile`, syncs attachments, and commits to Git. Stores any write error in `@subwikifiles_write_error`.
- **`after_find :load_from_md_file_with_frontmatter`**: Updates the wiki content on load only if the file is newer, `conflict_strategy` is `file_wins` or `manual`, and `SyncState` confirms an unambiguous `:to_wiki` change.

### 4.2 `WikiPagePatch` (`wiki_page_patch.rb`)
- **`before_save :handle_title_change`**: Renames the `.md` file on disk and commits `git mv`.
- **`after_save :update_frontmatter_on_parent_change`**: Re-saves content when `parent_id` changes so the YAML frontmatter reflects the new parent.
- **`before_destroy :delete_file`**: Does **not** delete the `.md` file on disk. Instead, it removes the `KnownFile` entry and leaves the file on disk (whose frontmatter still carries `id: <deleted_page_id>`), which `SyncPlan` surfaces under **"Delete?"** (`page_deleted`).

### 4.3 `WikiControllerPatch` (`wiki_controller_patch.rb`)
- **`before_action :sync_from_filesystem`** (`index`, `show`, `edit`): Calls `ProjectSync#sync_project_files` and uses `flash.now` (capped at 10 listed orphan files) to avoid `ActionDispatch::Cookies::CookieOverflow`.
- **`before_action :check_file_consistency`** (`show`, `edit`): Checks for external file locks (`FileLockChecker`) and applies unambiguous single-page updates via `ProjectSync#sync_page`.

### 4.4 `ProjectPatch` (`project_patch.rb`)
- Renames project folders on disk when a project's name or identifier changes in Redmine (when `conflict_strategy` is `db_wins` or `manual`), and updates `.project` metadata.

---

## 5. Services

- **`SyncState` (`sync_state.rb`)**: Read-only 3-way classifier comparing normalized wiki text, normalized file body, and `git show HEAD:<rel>`. Returns `Result(state, fallback, file_path, file_body)`.
- **`SyncPlan` (`sync_plan.rb`)**: Builds dry-run actions across four scopes (`page`, `branch`, `wiki`, `tree`), distinguishes unambiguous (`certain?`) actions from those needing user decisions (`conflict`, `deleted`, `page_deleted`, `pending`, `attachment`), and executes `apply`.
- **`ProjectSync` (`project_sync.rb`)**: Orchestrates `GitSync`, folder rename detection, and `FileScanner` + `WikiImporter` during page loads.
- **`WikiImporter` (`wiki_importer.rb`)**: Imports `.md` files into Redmine, handles ID-based renames, skips files referencing deleted pages (`deleted_page_reference?`), and creates experimental `{{child_pages}}` placeholder parent pages when a referenced parent does not exist yet.
- **`AttachmentImporter` (`attachment_importer.rb`)**: Attaches a file from the project root to a wiki page/wiki/project and moves the file into `_attachments/`.

---

## 6. Controller and Routes

| Route | Method | Action | Purpose |
|:---|:---|:---|:---|
| `GET projects/:project_id/subwikifiles/plan` | GET | `plan` | Read-only dry-run sync plan (JSON) |
| `POST projects/:project_id/subwikifiles/auto` | POST | `auto` | Throttled background auto-sync of certain actions + remaining plan (JSON) |
| `POST projects/:project_id/subwikifiles/apply` | POST | `apply` | Execute sync plan for a chosen scope and user decisions |
| `POST projects/:project_id/subwikifiles/fix_frontmatter` | POST | `fix_frontmatter` | Import orphan `.md` files as wiki pages (AJAX) |
| `POST projects/:project_id/subwikifiles/attach_file` | POST | `attach_file` | Attach non-Markdown file and move to `_attachments` (AJAX) |
| `POST projects/:project_id/subwikifiles/restore_file` | POST | `restore_file` | Restore missing `.md` file from wiki page |
| `POST (projects/:project_id/)subwikifiles/create_subproject_from_folder` | POST | `create_subproject_from_folder` | Create project/subproject from unassigned folder (AJAX) |
| `POST (projects/:project_id/)subwikifiles/orphan_folder` | POST | `orphan_folder` | Move unassigned folder to `_orphaned` (AJAX) |

---

## 7. UI Integration (`SyncUiHooks` & `ViewHooks`)

### `SyncUiHooks` (`sync_ui_hooks.rb`)
Inlines JS and CSS into `view_layouts_base_html_head` so assets work identically across Redmine 4, 5, 6, and 7 without asset pipeline steps:
- **On `WikiController#show` and `#index`**: Injects `subwikifiles_sync.css` and `subwikifiles_sync.js`. Places the status chip (`<a class="icon icon-reload swf-chip">`) in `#content > .contextual`, triggers a background `POST .../auto` after 300 ms, updates the chip badge/color if child pages or subprojects have pending changes, and renders the 4-scope sync popover on click.
- **On `WikiController#edit`** (when `live_preview_enabled?`): Injects `subwikifiles_live_preview.css` and `subwikifiles_live_preview.js`. Adds the **Split** tab between **Edit** and **Preview**, renders a side-by-side editor and live preview with a draggable divider (`20%`–`80%`, double-click for `50/50`, stored in `localStorage`), debounced AJAX preview rendering (`280 ms` + `AbortController`), and bidirectional proportional scroll synchronization.

### `ViewHooks` (`view_hooks.rb`)
- Injects the native Redmine `.flash.warning` prompt for newly detected folders (`build_folder_js` / `build_folder_css`).
- Injects the `✓` quick-import buttons in the orphan files notice (`build_js`) and displays the associated relative file path in the wiki editor.

---

## 8. Configuration and Permissions

### Plugin Settings (`init.rb`)

| Key | Default | Description |
|:---|:---|:---|
| `base_path` | `/var/lib/redmine/wiki_files` | Absolute path for wiki files (whitespace stripped via `RedmineSubwikifiles.base_path`) |
| `enabled` | `false` | Global activation (otherwise per project via module) |
| `conflict_strategy` | `'file_wins'` | Conflict resolution default: `'file_wins'`, `'db_wins'`, `'manual'` |
| `live_preview` | `'1'` | Enables the HedgeDoc-style live split preview in the wiki editor |

---

## 9. Synchronization Flow in Detail

1. **Page Load (`WikiController#show`):**
   - `WikiControllerPatch#sync_from_filesystem` runs `ProjectSync#sync_project_files` for the current project.
   - `SyncUiHooks` renders the initial status chip for the current page.
   - 300 ms after `DOMContentLoaded`, `subwikifiles_sync.js` calls `POST /projects/:id/subwikifiles/auto`.
   - If the project tree's 60 s throttle slot is free, `SyncPlan#apply('tree', {}, only_certain: true)` executes all unambiguous sync actions across the project and its subprojects.
   - The remaining uncertain actions (conflicts, deletions, unassigned files) are returned as JSON and reflected in the status chip and 4-scope popover.

2. **Interactive Sync (`POST /projects/:id/subwikifiles/apply`):**
   - User selects a scope (`page`, `branch`, `wiki`, `tree`) and chooses actions for conflicts (`file` / `wiki` / `skip`) or deletions (`delete_page` / `restore` / `delete_file` / `reimport` / `skip`, with confirmation dialog).
   - `SyncPlan#apply` executes the selected actions and commits resolved files to Git.

---

## 10. Known Pitfalls and Invariants

- **Loop Prevention:** Every automated database or file change must wrap its operations in `RedmineSubwikifiles.without_auto_sync { ... }` so `WikiContentPatch` and `ProjectPatch` callbacks do not trigger recursive writes.
- **Session Cookie Size Limit (4 KB):** Page-view sync notices must always use `flash.now[...]` (never `flash[...]`) and cap listed filenames so projects with many unassigned files never trigger `ActionDispatch::Cookies::CookieOverflow`.
- **Frontmatter Stripping:** `GitSync` and `SyncPlan` must only write `SyncState.body(raw)` into `WikiContent#text`, and `WikiContentPatch#text_without_frontmatter` guards against saving frontmatter headers into the database.
- **Never Auto-Delete:** Neither `WikiPagePatch#delete_file` nor `GitSync` nor `SyncPlan` may automatically delete a wiki page or a file on disk without explicit user confirmation in the popover.
