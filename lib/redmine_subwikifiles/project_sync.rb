module RedmineSubwikifiles
  # Automatic synchronization that runs on wiki page views (current project / current page).
  # Only unambiguous changes are applied automatically; conflicts are left for the
  # sync popover (see SyncState / SyncPlan).
  class ProjectSync
    attr_reader :project, :storage

    def initialize(project)
      @project = project
      @storage = FileStorage.new(project)
    end

    def self.enabled_for?(project)
      RedmineSubwikifiles.enabled_for?(project)
    end

    # Project-level sync: filesystem renames/modifications (Git), folder renames,
    # and import of new files with frontmatter.
    # Returns { imported: [], renamed: [], manual_orphans: [], locked: [] }
    def sync_project_files
      # With 'db_wins' external file modifications must not overwrite wiki pages,
      # so the Git-based change detection (which updates pages from modified files) is skipped.
      git_sync = nil
      if RedmineSubwikifiles.conflict_strategy != 'db_wins'
        begin
          git_sync = GitSync.new(project)
          git_sync.sync_from_filesystem
        rescue => e
          Rails.logger.error "RedmineSubwikifiles: GitSync failed: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end

      begin
        sync_folder_renames_to_redmine
      rescue => e
        Rails.logger.error "RedmineSubwikifiles: Folder rename sync failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end

      scan_result = FileScanner.new(project).scan_for_new_files
      Rails.logger.info "RedmineSubwikifiles: Found #{scan_result[:orphaned].count} new files, #{scan_result[:locked].count} locked"

      # Auto-import ONLY files that have valid frontmatter
      # (files of pages deleted in Redmine are never re-imported automatically)
      deleted_refs, orphaned = scan_result[:orphaned].partition { |f| f[:has_frontmatter] && WikiImporter.deleted_page_reference?(f[:metadata]) }
      to_import = orphaned.select { |f| f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter] }
      # Manual orphans: Files without frontmatter + attachments + invalid files
      manual_orphans = orphaned.reject { |f| f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter] }
      Rails.logger.info "RedmineSubwikifiles: #{deleted_refs.size} file(s) of deleted pages left for decision" if deleted_refs.any?

      imported = git_sync ? git_sync.imported.dup : []
      placeholders = git_sync ? git_sync.placeholders.dup : []
      renamed = []
      if to_import.any?
        result = WikiImporter.new(project).import_files(to_import)
        imported += result[:imported]
        placeholders += result[:placeholders]
        renamed = result[:renamed]
        # Failed imports stay orphans
        manual_orphans += result[:skipped]
      end

      { imported: imported, renamed: renamed, manual_orphans: manual_orphans, locked: scan_result[:locked],
        placeholders: placeholders.uniq }
    end

    # Page-level automatic sync on page view.
    # Applies a file change to the wiki only if it is unambiguous (three-way comparison:
    # only the file changed since the last common state). Nothing is applied with 'db_wins'.
    # Everything else (missing file, wiki newer, conflict, deleted file) is shown in the sync chip.
    # Returns the SyncState state (:updated if the page was updated from the file).
    def sync_page(page)
      content = page.content
      return :ok unless content

      result = SyncState.new(project, storage: storage).classify(page, content)
      return result.state unless result.state == :to_wiki
      return result.state if RedmineSubwikifiles.conflict_strategy == 'db_wins'

      update_page_from_file(page, result.file_path, result.file_body) ? :updated : result.state
    end

    private

    def update_page_from_file(page, file_path, content_only)
      git_author = nil
      begin
        git_author = GitBackend.new(project).last_commit_author(file_path)
      rescue => e
        Rails.logger.warn "RedmineSubwikifiles: Could not get git author: #{e.message}"
      end
      author_text = git_author ? " (Author: #{git_author})" : ""

      page.content.text = content_only
      page.content.comments = "Auto-updated from file '#{page.title}.md'#{author_text}"
      # Save the content itself (WikiPage#save does not reliably persist a changed content)
      page.content.save
    end

    # Detect folder renames in the filesystem and sync them to Redmine project names.
    # Only applies when conflict_strategy is 'file_wins' or 'manual'.
    # With 'db_wins', the filesystem is expected to follow Redmine, not vice versa.
    def sync_folder_renames_to_redmine
      return if RedmineSubwikifiles.conflict_strategy == 'db_wins'

      sync_single_project_name(project)

      # Also check direct subprojects
      project.children.active.each do |child|
        next unless child.module_enabled?(:redmine_subwikifiles) || Setting.plugin_redmine_subwikifiles['enabled']
        sync_single_project_name(child)
      end
    end

    # For a single project: compare the actual folder name to the project name.
    # If different, update the project name in Redmine.
    def sync_single_project_name(proj)
      folder_path = FileStorage.new(proj).project_path
      Rails.logger.info "RedmineSubwikifiles: sync_single_project_name '#{proj.identifier}': folder_path=#{folder_path}, exists=#{Dir.exist?(folder_path)}"
      return unless Dir.exist?(folder_path)

      folder_name = File.basename(folder_path)

      Rails.logger.info "RedmineSubwikifiles: sync_single_project_name '#{proj.identifier}': folder_name='#{folder_name}', project.name='#{proj.name}', match=#{folder_name == proj.name}"
      # Nothing to do if names match
      return if folder_name == proj.name

      Rails.logger.info "RedmineSubwikifiles: Folder rename detected for '#{proj.identifier}': " \
                        "project name='#{proj.name}', folder name='#{folder_name}'. Syncing to Redmine."

      # Update project name to match folder, suppress our own after_save callback
      RedmineSubwikifiles.without_auto_sync do
        proj.name = folder_name
        if proj.save
          Rails.logger.info "RedmineSubwikifiles: Updated project name to '#{folder_name}'"
          FileStorage.write_project_metadata(folder_path, proj)
        else
          Rails.logger.error "RedmineSubwikifiles: Failed to update project name: #{proj.errors.full_messages.join(', ')}"
        end
      end
    end
  end
end
