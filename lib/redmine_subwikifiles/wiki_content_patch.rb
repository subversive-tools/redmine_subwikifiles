module RedmineSubwikifiles
  # Patch for WikiContent model. 
  # Handles writing wiki content to the filesystem and creating Git commits on every save.
  module WikiContentPatch
    extend ActiveSupport::Concern

    included do
      Rails.logger.info "RedmineSubwikifiles: WikiContentPatch included in #{self.name}"
      before_save :write_to_md_file_with_frontmatter
      after_find :load_from_md_file_with_frontmatter
    end

    def write_to_md_file_with_frontmatter
      return unless plugin_enabled?
      return if Thread.current[:redmine_subwikifiles_syncing]
      
      storage = RedmineSubwikifiles::FileStorage.new(page.project)
      
      # Build frontmatter metadata
      metadata = build_frontmatter_metadata
      
      # Combine metadata + content
      full_content = RedmineSubwikifiles::FrontmatterParser.build(metadata, text_without_frontmatter)
      
      # Write to file (just page title, no hierarchy in filename)
      @subwikifiles_write_error = nil
      unless storage.write(page.title, full_content)
        @subwikifiles_write_error = storage.last_error || 'unknown error'
        return
      end
      RedmineSubwikifiles::KnownFile.remember(page, storage.resolve_existing_path(page.title))
      
      # Sync attachments to FS
      if defined?(AttachmentHandler)
        AttachmentHandler.new(page).sync_to_fs
      end
      
      # Git commit
      if defined?(RedmineSubwikifiles::GitBackend)
        RedmineSubwikifiles::GitBackend.new(page.project).commit(
          page.title,
          author: User.current,
          message: I18n.t('redmine_subwikifiles.git_commit_message', page_title: page.title)
        )
      end
    rescue => e
      @subwikifiles_write_error = e.message
      Rails.logger.error "RedmineSubwikifiles: Error writing MD file: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end

    # Error message of the last failed file write (nil on success)
    attr_reader :subwikifiles_write_error
    
    def load_from_md_file_with_frontmatter
      return unless plugin_enabled?
      return if Thread.current[:redmine_subwikifiles_syncing]
      
      storage = RedmineSubwikifiles::FileStorage.new(page.project)
      file_data = storage.read(page.title)
      
      return unless file_data
      
      file_content, file_mtime = file_data
      
      # Parse frontmatter
      parsed = RedmineSubwikifiles::FrontmatterParser.parse(file_content)
      content_only = parsed[:content]
      metadata = parsed[:metadata]
      
      # Conflict strategy handling
      strategy = RedmineSubwikifiles.conflict_strategy
      
      # If file is newer than DB record
      if file_mtime > updated_on && %w[file_wins manual].include?(strategy)
        # Only update if content changed and only the file changed since the last common state
        # (three-way check; conflicts are left for the sync popover)
        if self.text != content_only && unambiguous_file_change?
          self.text = content_only
          
          # Get author from git
          git_author = nil
          begin
            file_path = storage.file_path(page.title)
            if file_path && File.exist?(file_path)
              backend = RedmineSubwikifiles::GitBackend.new(page.project)
              git_author = backend.last_commit_author(file_path)
            end
          rescue => e
            Rails.logger.warn "RedmineSubwikifiles: Could not get git author: #{e.message}"
          end
          
          author_text = git_author ? " (Author: #{git_author})" : ""
          
          RedmineSubwikifiles.without_auto_sync do
            self.comments = "Updated from filesystem#{author_text}"
            self.save!
            Rails.logger.info "RedmineSubwikifiles: Updated WikiPage #{page.title} from filesystem."
            Thread.current[:redmine_subwikifiles_just_updated] = true
          end
          
          if defined?(AttachmentHandler) && page
            AttachmentHandler.new(page).sync_from_fs
          end
        end
        
        # Sync parent relationship from frontmatter (even if content didn't change)
        sync_parent_from_metadata(metadata)
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Error reading MD file: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end

    private

    def unambiguous_file_change?
      RedmineSubwikifiles.without_auto_sync do
        RedmineSubwikifiles::SyncState.new(page.project).classify(page, self).state == :to_wiki
      end
    end

    # Wiki text without a leading frontmatter block. Guards against duplicated headers
    # if a frontmatter block ever ended up in the wiki text (the metadata is always rebuilt from the DB).
    def text_without_frontmatter
      parsed = RedmineSubwikifiles::FrontmatterParser.parse(text.to_s)
      if parsed[:metadata].is_a?(Hash) && parsed[:metadata].present?
        Rails.logger.warn "RedmineSubwikifiles: Stripped frontmatter from wiki text of '#{page&.title}'"
        parsed[:content]
      else
        text
      end
    rescue => e
      Rails.logger.warn "RedmineSubwikifiles: Could not check wiki text for frontmatter: #{e.message}"
      text
    end

    def plugin_enabled?
      RedmineSubwikifiles.enabled_for?(page&.project)
    end

    def build_frontmatter_metadata
      metadata = {}
      
      # Parent page
      if page.parent_id
        parent_page = WikiPage.find_by(id: page.parent_id)
        metadata['parent'] = parent_page.title if parent_page
      end
      
      # Add Wiki Page ID for robust rename handling
      metadata['id'] = page.id
      
      # Note: WikiPage doesn't have a 'position' attribute in Redmine 6
      # Order is determined by alphabetical sorting or explicit ordering in the UI
      
      # Creation date
      metadata['created'] = page.created_on.iso8601 if page.created_on
      
      # Updated date
      metadata['updated'] = updated_on.iso8601 if updated_on
      
      metadata.compact
    end
    
    def sync_parent_from_metadata(metadata)
      return unless metadata.is_a?(Hash)
      return unless metadata['parent']
      
      parent_title = metadata['parent']
      parent_page = page.wiki.pages.find_by(title: parent_title)
      
      if parent_page && page.parent_id != parent_page.id
        RedmineSubwikifiles.without_auto_sync do
          page.parent_id = parent_page.id
          page.save!
          Rails.logger.info "RedmineSubwikifiles: Updated parent for '#{page.title}' to '#{parent_title}'"
        end
      elsif metadata['parent'] && !parent_page
        Rails.logger.warn "RedmineSubwikifiles: Parent '#{parent_title}' not found for page '#{page.title}'"
      end
    end
  end
end
