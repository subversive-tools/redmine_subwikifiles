module RedmineSubwikifiles
  module ProjectPatch
    def self.included(base)
      base.send(:include, InstanceMethods)
      base.class_eval do
        after_save :rename_subwikifiles_folder_on_identifier_change, if: :saved_change_to_identifier?
        after_save :rename_subwikifiles_folder_on_name_change, if: :saved_change_to_name?
      end
    end

    module InstanceMethods
      # Handle identifier changes (existing logic, maybe less common)
      def rename_subwikifiles_folder_on_identifier_change
        perform_rename(saved_change_to_identifier[0], saved_change_to_identifier[1], :identifier)
      end

      # Handle name changes (folder name sync)
      def rename_subwikifiles_folder_on_name_change
        perform_rename(nil, nil, :name)
      end

      private

      def perform_rename(old_id, new_id, change_type)
        # Don't react to our own sync updates (prevents ping-pong)
        return if Thread.current[:redmine_subwikifiles_syncing]

        # Skip on project creation (old value is nil for both identifier and name)
        if change_type == :identifier
          return if old_id.blank?
        elsif change_type == :name
          old_name = saved_change_to_name&.first
          return if old_name.blank?
        end

        # Only proceed if the plugin is enabled specifically for this project or globally
        is_globally_enabled = Setting.plugin_redmine_subwikifiles['enabled']
        return unless self.module_enabled?(:redmine_subwikifiles) || is_globally_enabled

        # Respect conflict_strategy setting:
        #   file_wins  → filesystem is authoritative, don't rename folders from Redmine
        #   db_wins    → Redmine is authoritative, rename folder to match project name
        #   manual     → bidirectional sync, rename folder to match project name
        conflict_strategy = Setting.plugin_redmine_subwikifiles['conflict_strategy'] || 'file_wins'
        
        if conflict_strategy == 'file_wins'
          # File system is authoritative – only update .project metadata, don't touch folder name
          Rails.logger.info "RedmineSubwikifiles: conflict_strategy=file_wins, skipping folder rename for '#{name}'. Updating metadata only."
          update_metadata_only
          return
        end

        base_path = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
        
        # Determine parent path
        if parent
          require File.expand_path('../file_storage', __FILE__)
          # Use parent (which is already saved/exists)
          parent_path = RedmineSubwikifiles::FileStorage.new(parent).project_path
        else
          parent_path = base_path
        end

        return unless Dir.exist?(parent_path)
        
        target_folder = nil
        
        # Strategy depends on what changed
        if change_type == :identifier
           Rails.logger.info "RedmineSubwikifiles: Project identifier changed from #{old_id} to #{new_id}. Syncing folder..."
           # Look for folder matching old identifier OR containing .project with old identifier
           possible_path = File.join(parent_path, old_id)
           if Dir.exist?(possible_path)
              target_folder = possible_path
           else
              # Scan for ID
              target_folder = scan_for_project_folder(parent_path, old_id)
           end
        else
           # Name changed.Identifier is stable.
           # Find folder by current identifier
           Rails.logger.info "RedmineSubwikifiles: Project name changed to '#{name}'. Syncing folder name..."
           target_folder = scan_for_project_folder(parent_path, identifier)
           
           # Fallback: check if a folder with the identifier name exists directly
           unless target_folder
             check_path = File.join(parent_path, identifier)
             target_folder = check_path if Dir.exist?(check_path)
           end
        end

        if target_folder
          # Calculate new folder name
          # Keep the original name as-is to preserve folder naming (no sanitization)
          new_folder_name = name
          
          # If the resulting name is empty or too short, fallback to identifier
          new_folder_name = identifier if new_folder_name.blank?

          new_folder_path = File.join(parent_path, new_folder_name)
          
          if target_folder == new_folder_path
             # Exact same path string, nothing to rename
             update_project_metadata(target_folder)
             return
          end

          # Check if target already exists AND is a different folder
          # File.realpath resolves symlinks and case on case-insensitive FS,
          # so identical realpath = same folder (works on Linux, macOS, Windows)
          target_is_same_folder = File.exist?(new_folder_path) && 
                                  File.realpath(target_folder) == File.realpath(new_folder_path)

          if !File.exist?(new_folder_path) || target_is_same_folder
             # Safe to rename: either target doesn't exist, or it's the same folder
             # (e.g. case-only rename on case-insensitive FS)
             begin
               File.rename(target_folder, new_folder_path)
               Rails.logger.info "RedmineSubwikifiles: Renamed folder '#{target_folder}' to '#{new_folder_path}'"
               update_project_metadata(new_folder_path)
             rescue => e
               Rails.logger.error "RedmineSubwikifiles: Failed to rename folder: #{e.message}"
             end
          else
             Rails.logger.warn "RedmineSubwikifiles: Cannot rename folder '#{target_folder}' to '#{new_folder_path}'. A different folder with that name already exists."
             update_project_metadata(target_folder)
          end
        else
          Rails.logger.info "RedmineSubwikifiles: No existing folder found for identifier '#{identifier}' in '#{parent_path}'. Skipping rename."
        end
      end

      def scan_for_project_folder(parent_path, search_id)
        Dir.foreach(parent_path) do |entry|
          next if entry.start_with?('.')
          next if ['_orphaned', '_attachments', '_projects'].include?(entry)
          
          check_path = File.join(parent_path, entry)
          next unless Dir.exist?(check_path)
          
          project_file = File.join(check_path, '.project')
          if File.exist?(project_file)
            begin
              content = File.read(project_file, encoding: 'UTF-8')
              if content =~ /id:\s*#{Regexp.escape(search_id)}\s*$/
                return check_path
              end
            rescue
              next
            end
          end
        end
        nil
      end

      def update_project_metadata(folder_path)
        require File.expand_path('../file_storage', __FILE__)
        RedmineSubwikifiles::FileStorage.write_project_metadata(folder_path, self)
      end

      # Update only .project metadata without renaming the folder
      def update_metadata_only
        require File.expand_path('../file_storage', __FILE__)
        begin
          folder_path = RedmineSubwikifiles::FileStorage.new(self).project_path
          if Dir.exist?(folder_path)
            update_project_metadata(folder_path)
          end
        rescue => e
          Rails.logger.error "RedmineSubwikifiles: Failed to update metadata: #{e.message}"
        end
      end
    end
  end
end
