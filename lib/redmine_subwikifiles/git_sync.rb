module RedmineSubwikifiles
  # Orchestrates the synchronization process from the filesystem to the Redmine database.
  # Detects changes in the Git repository and updates corresponding WikiPages.
  class GitSync
    def initialize(project)
      @project = project
      @backend = GitBackend.new(project)
      @storage = FileStorage.new(project)
      @imported = []
      @placeholders = []
      @conflicted = []
    end

    # Pages imported / placeholder parent pages created during the last sync_from_filesystem
    attr_reader :imported, :placeholders
    
    # Sync filesystem changes to Redmine
    def sync_from_filesystem
      Rails.logger.info "RedmineSubwikifiles: DEBUG: sync_from_filesystem START"
      
      # Stage all changes first so git can detect renames
      @backend.run_git('add', '-A')
      
      changes = @backend.detect_changes
      Rails.logger.info "RedmineSubwikifiles: DEBUG: Detected changes: #{changes.inspect}"
      
      # Process in order: delete, rename, modify, add
      # This prevents conflicts if a page was deleted and recreated
      
      changes[:deleted].each do |file|
        Rails.logger.info "RedmineSubwikifiles: File #{file} deleted from filesystem. Keeping wiki page."
      end
      
      changes[:renamed].each do |old_file, new_file|
        rename_page_in_redmine(old_file, new_file)
      end
      
      changes[:modified].each do |file|
        update_page_content(file)
      end
      
      changes[:added].each do |file|
        create_page_in_redmine(file)
      end
      
      # Commit the sync (add all changes, except unresolved conflicts which must keep their base)
      @backend.run_git('add', '-A') if changes.values.any?(&:any?)
      @conflicted.each { |f| @backend.run_git('reset', '-q', '--', f) rescue nil }
      @backend.run_git('commit', '-m', 'Synced from filesystem', '--allow-empty') rescue nil
      
      Rails.logger.info "RedmineSubwikifiles: Synced #{changes.values.flatten.size} changes from filesystem"
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Sync from filesystem failed: #{e.message}"
    end
    
    private
    
    def rename_page_in_redmine(old_file, new_file)
      return unless old_file.end_with?('.md') && new_file.end_with?('.md')
      
      old_title = file_to_title(old_file)
      new_title = file_to_title(new_file)
      
      page = find_page_by_title(old_title)
      
      if page
        RedmineSubwikifiles.without_auto_sync { page.update(title: new_title) }
        Rails.logger.info "RedmineSubwikifiles: Renamed page '#{old_title}' to '#{new_title}' (file renamed)"
      end
    end
    
    def update_page_content(file)
      return unless file.end_with?('.md')
      
      title = file_to_title(file)
      page = find_page_by_title(title)
      
      return unless page
      
      RedmineSubwikifiles.without_auto_sync do
        content = page.content
        return unless content
        
        # Three-way check against the last committed state: apply only if just the file changed.
        # Conflicts are not committed, so they keep their base and show up in the sync popover.
        result = SyncState.new(@project, storage: @storage).classify(page, content)
        unless result.state == :to_wiki
          @conflicted << file if result.state == :conflict
          Rails.logger.info "RedmineSubwikifiles: Not applying modified file '#{file}' (state: #{result.state})"
          return
        end
        
        # Only the body goes into the wiki - the frontmatter stays in the file
        page.content.text = result.file_body
        page.content.comments = "Updated from filesystem (Git)"
        page.content.save
        
        Rails.logger.info "RedmineSubwikifiles: Updated page '#{title}' (file modified)"
      end
    end
    
    # New file detected by Git: import it through WikiImporter (the same path as the file scanner),
    # so frontmatter is stripped from the page text and the parent relationship is applied.
    # Files without frontmatter are left for the manual assignment ("pending files").
    def create_page_in_redmine(file)
      return unless file.end_with?('.md')
      return if file.include?('/') # files in subfolders belong to subprojects

      file_path = File.join(@storage.project_path, file)
      return unless File.file?(file_path)

      filename = File.basename(file, '.md')
      title = Wiki.titleize(filename)
      return if @project.wiki && @project.wiki.pages.find_by(title: title)

      parsed = FrontmatterParser.parse(File.read(file_path, encoding: 'UTF-8'))
      unless parsed[:metadata].present?
        Rails.logger.info "RedmineSubwikifiles: Skipping creation of page '#{title}': No frontmatter found"
        return
      end

      if WikiImporter.deleted_page_reference?(parsed[:metadata])
        Rails.logger.info "RedmineSubwikifiles: '#{file}' belongs to a deleted page - not re-imported"
        return
      end

      @project.create_wiki unless @project.wiki

      result = WikiImporter.new(@project).import_files([{
        path: file_path,
        filename: filename,
        type: 'wiki',
        has_frontmatter: true,
        metadata: parsed[:metadata],
        content: parsed[:content],
        valid: true,
        errors: []
      }])
      @imported.concat(result[:imported])
      @placeholders.concat(result[:placeholders])
      result[:skipped].each do |s|
        Rails.logger.error "RedmineSubwikifiles: Failed to import '#{s[:file]}': #{Array(s[:errors]).join(', ')}"
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to import new file '#{file}': #{e.message}"
    end
    
    def file_to_title(file)
      # Remove .md extension and convert path separators to hierarchy
      # e.g., "Parent/Child.md" -> "Parent/Child"
      file.sub(/\.md$/, '').gsub('_', ' ')
    end
    
    def find_page_by_title(title)
      return nil unless @project.wiki
      
      # Handle hierarchical titles
      parts = title.split('/')
      
      if parts.size == 1
        # Top-level page
        @project.wiki.pages.find_by(title: title)
      else
        # Nested page - need to match by full path
        # This is tricky because Redmine doesn't store full paths
        # We need to find by the last part and check ancestors
        page_title = parts.last
        @project.wiki.pages.where(title: page_title).find do |page|
          full_title = ([page.ancestors.map(&:title)] + [page.title]).flatten.join('/')
          full_title == title
        end
      end
    end
  end
end
