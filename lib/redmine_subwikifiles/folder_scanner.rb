module RedmineSubwikifiles
  # Scans for unassigned folders within a project's base directory.
  # Unassigned folders are those that do not yet have a corresponding Redmine subproject.
  class FolderScanner
    attr_reader :project
    
    def initialize(project = nil)
      @project = project
      @is_global = project.nil?
      
      # Fetch base path from settings, default to /var/lib/redmine/wiki_files if not set
      @base_path = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
      
      if @is_global
        @project_path = @base_path
      else
        # Use FileStorage to retrieve the correct project path (supporting nesting)
        require File.expand_path('../file_storage', __FILE__)
        @project_path = FileStorage.new(project).project_path
      end
    end
    
    # Scans for child directories in the project root that are not active subprojects.
    # @return [Array<Hash>] An array of folder detail hashes.
    def scan_all_folders
      return [] unless Dir.exist?(@project_path)
      
      unassigned = []
      
      Dir.foreach(@project_path) do |entry|
        next if entry.start_with?('.')
        next if entry.end_with?('.md')
        next if ['_orphaned', '_attachments', '_projects'].include?(entry)
        
        full_path = File.join(@project_path, entry)
        next unless Dir.exist?(full_path)
        
        # Check if this folder corresponds to a subproject
        if subproject_exists?(entry)
          # It's an assigned subproject folder.
          # We skip it.
        else
          # It's an unassigned folder
          unassigned << {
            path: full_path,
            name: entry,
            parent_project: @project,
            misplaced: false, # Direct child is valid
            relative_path: entry,
            depth: 0
          }
        end
      end
      
      unassigned
    end
    
    # Legacy method for backward compatibility
    def unassigned_folders
      scan_all_folders.map { |f| f[:name] }
    end
    
    private
    
    def subproject_exists?(folder_name)
      # Normalize folder name the same way as when creating subprojects
      normalized_name = folder_name.downcase.gsub(/[^a-z0-9\-]/, '-').gsub(/\-+/, '-').gsub(/^\-|\-$/, '')
      
      if @is_global
        # In global mode, check if any top-level project matches the folder name
        Project.where(parent_id: nil).active.any? do |p| 
          p.identifier == folder_name || p.identifier == normalized_name
        end
      else
        # In project mode, check if any child project matches the folder name
        @project.children.active.any? do |child| 
          child.identifier == folder_name || child.identifier == normalized_name
        end
      end
    end
  end
end
