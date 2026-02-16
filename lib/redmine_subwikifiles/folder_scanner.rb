module RedmineSubwikifiles
  # Scans for unassigned folders within a project's base directory.
  # Unassigned folders are those that do not have a .project metadata file.
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
        next if ['_orphaned', '_attachments'].include?(entry)
        
        full_path = File.join(@project_path, entry)
        next unless Dir.exist?(full_path)
        
        # Check if this folder has a .project metadata file
        if has_project_metadata?(full_path)
          # It's an assigned subproject folder - skip it
        else
          # It's an unassigned folder
          unassigned << {
            path: full_path,
            name: entry,
            parent_project: @project,
            misplaced: false,
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
    
    # Check if folder has a .project metadata file
    def has_project_metadata?(folder_path)
      project_file = File.join(folder_path, '.project')
      File.exist?(project_file)
    end
  end
end
