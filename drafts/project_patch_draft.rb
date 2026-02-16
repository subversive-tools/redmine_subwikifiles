module RedmineSubwikifiles
  module ProjectPatch
    def self.included(base)
      base.send(:include, InstanceMethods)
      base.class_eval do
        after_save :rename_subwikifiles_folder, if: :saved_change_to_identifier?
      end
    end

    module InstanceMethods
      def rename_subwikifiles_folder
        # Only proceed if the plugin is enabled specifically for this project or globally
        is_globally_enabled = Setting.plugin_redmine_subwikifiles['enabled']
        return unless self.module_enabled?(:redmine_subwikifiles) || is_globally_enabled

        old_identifier = saved_change_to_identifier[0]
        new_identifier = saved_change_to_identifier[1]
        
        return if old_identifier.blank? || new_identifier.blank?

        Rails.logger.info "RedmineSubwikifiles: Project identifier changed from #{old_identifier} to #{new_identifier}. Attempting to rename folder."

        # We need to construct the old path manually or by instantiation a temporary object if possible, 
        # but FileStorage might rely on the live project object.
        # Let's see how FileStorage works.
        
        # If FileStorage takes the project, it uses the *current* identifier. 
        # We might need to manually construct the old path based on the logic we see in FileStorage.
        
        base_path = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
        
        # If it's a root project
        if parent_id.nil?
          old_path = File.join(base_path, old_identifier)
          new_path = File.join(base_path, new_identifier)
        else
          # Subproject: This is trickier if FileStorage handles deep nesting. 
          # We should probably defer to FileStorage logic but we need to temporarily trick it or copy the logic.
          # Ideally, FileStorage would allow passing an identifier override.
          
          # Let's inspect FileStorage first.
        end
      end
    end
  end
end
