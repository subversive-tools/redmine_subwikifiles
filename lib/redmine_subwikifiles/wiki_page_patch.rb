module RedmineSubwikifiles
  # Patch for WikiPage model.
  # Handles filesystem renames and deletions when a wiki page is updated or destroyed in Redmine.
  module WikiPagePatch
    extend ActiveSupport::Concern

    included do
      Rails.logger.info "RedmineSubwikifiles: WikiPagePatch included in #{self.name}"
      before_save :handle_title_change
      after_save :update_frontmatter_on_parent_change
      before_destroy :delete_file
    end

    def handle_title_change
      return unless plugin_enabled?
      return unless title_changed? && persisted?
      
      # Get old and new titles with full hierarchy
      old_full_title = get_full_title_from(title_was)
      new_full_title = get_full_title_from(title)
      
      storage = RedmineSubwikifiles::FileStorage.new(project)
      old_path = storage.file_path(old_full_title)
      new_path = storage.file_path(new_full_title)
      
      # Rename file if it exists
      if File.exist?(old_path)
        # Ensure target directory exists
        FileUtils.mkdir_p(File.dirname(new_path))
        
        # Move the file
        FileUtils.mv(old_path, new_path)
        Rails.logger.info "RedmineSubwikifiles: Renamed #{old_path} to #{new_path}"
        
        # Handle Git rename
        if defined?(RedmineSubwikifiles::GitBackend)
          begin
            RedmineSubwikifiles::GitBackend.new(project).rename(
              title_was,
              title,
              author: User.current,
              message: "Renamed: #{title_was} → #{title}"
            )
          rescue => e
            Rails.logger.warn "RedmineSubwikifiles: Git rename failed: #{e.message}"
          end
        end
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Error renaming file: #{e.message}"
    end
    
    def update_frontmatter_on_parent_change
      return unless plugin_enabled?
      # If parent_id changed, trigger content save to update frontmatter
      if saved_change_to_parent_id? && content
        content.save
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Error updating frontmatter: #{e.message}"
    end
    
    # Deleting a wiki page no longer deletes its file automatically.
    # The remaining file (its header still carries the old page id) shows up in the sync popover
    # under "to be deleted", where the user decides: delete file / recreate page / skip.
    def delete_file
      return unless plugin_enabled?
      Rails.logger.info "RedmineSubwikifiles: Page '#{title}' deleted - file kept, listed as deletion candidate"
      RedmineSubwikifiles::KnownFile.forget(self)
    end
    
    private
    
    def plugin_enabled?
      RedmineSubwikifiles.enabled_for?(project)
    end
    
    def get_full_title_from(title_value)
      # With flat structure, we just use the title directly
      title_value
    end
  end
end
