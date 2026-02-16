module RedmineSubwikifiles
  # Manages the physical storage of wiki files on the filesystem.
  # Handles path calculation (including nested subprojects), reading, and writing.
  class FileStorage
    attr_reader :project_path
    
    def initialize(project)
      @project = project
      @project_identifier = project.identifier
      # Fetch base path from settings, default to /var/lib/redmine/wiki_files if not set
      @base_dir = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
      
      # Build path by finding folder with matching .project metadata
      @project_path = build_project_path(project)
    end
    
    private
    
    # Build the complete path for a project by searching for .project metadata files
    def build_project_path(project)
      if project.parent
        # Get parent path first
        parent_path = build_project_path(project.parent)
        # Search for subfolder with .project file matching this project's identifier
        found_path = find_project_folder(parent_path, project.identifier)
        return found_path if found_path

        # Check if a folder with the raw name exists (e.g. "Kroko isst Schoko")
        raw_name_path = File.join(parent_path, project.name)
        return raw_name_path if Dir.exist?(raw_name_path)

        # Fallback: check sanitized name for legacy folders
        name_path = File.join(parent_path, self.class.sanitize_filename(project.name))
        return name_path if Dir.exist?(name_path)

        # Default for new folder creation: use raw name to preserve original naming
        raw_name_path
      else
        # Top-level project: search in base_dir
        found_path = find_project_folder(@base_dir, project.identifier)
        return found_path if found_path

        # Check for existing folder by raw name
        raw_name_path = File.join(@base_dir, project.name)
        return raw_name_path if Dir.exist?(raw_name_path)

        # Fallback: check sanitized name for legacy folders
        name_path = File.join(@base_dir, self.class.sanitize_filename(project.name))
        return name_path if Dir.exist?(name_path)

        # Default for new folder creation: use raw name
        raw_name_path
      end
    end
    
    # Find a folder containing a .project file with matching id
    def find_project_folder(search_path, identifier)
      return nil unless Dir.exist?(search_path)
      
      Dir.foreach(search_path) do |entry|
        next if entry.start_with?('.')
        next if ['_orphaned', '_attachments'].include?(entry)
        
        full_path = File.join(search_path, entry)
        next unless Dir.exist?(full_path)
        
        project_file = File.join(full_path, '.project')
        if File.exist?(project_file)
          metadata = read_project_metadata(project_file)
          return full_path if metadata['id'] == identifier
        end
      end
      
      nil
    end
    
    # Read .project metadata file (YAML frontmatter style)
    def read_project_metadata(path)
      content = File.read(path, encoding: 'UTF-8')
      if content =~ /\A---\s*\n(.*?)\n---/m
        YAML.safe_load($1) || {}
      else
        {}
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to read .project file: #{e.message}"
      {}
    end
    
    public
    
    # Write .project metadata file
    def self.write_project_metadata(folder_path, project)
      project_file = File.join(folder_path, '.project')
      content = <<~YAML
        ---
        id: #{project.identifier}
        name: "#{project.name}"
        created: "#{Time.now.iso8601}"
        ---
      YAML
      File.write(project_file, content, encoding: 'UTF-8')
      Rails.logger.info "RedmineSubwikifiles: Created .project metadata in #{folder_path}"
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to write .project file: #{e.message}"
    end

    def file_exists?(title)
      !resolve_existing_path(title).nil?
    end

    def read(title)
      path = resolve_existing_path(title)
      return nil unless path
      
      content = File.read(path, encoding: 'UTF-8')
      mtime = File.mtime(path)
      [content, mtime]
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to read file for #{title}: #{e.message}"
      nil
    end

    def write(title, content)
      # Write to existing path if available, else default to sanitized
      path = resolve_existing_path(title) || file_path(title)
      
      # Ensure project directory exists
      FileUtils.mkdir_p(@project_path) unless File.directory?(@project_path)

      File.write(path, content, encoding: 'UTF-8')
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to write file for #{title}: #{e.message}"
    end

    # Returns the default path for a new file (sanitized)
    def file_path(title)
      sanitized = sanitize_filename(title)
      File.join(@project_path, "#{sanitized}.md")
    end
    
    private
    
    # Try to find an existing file matching the title variants
    def resolve_existing_path(title)
      # Variants to check
      variants = [
        sanitize_filename(title),         # Standard (underscores)
        title,                            # As-is (e.g. spaces)
        title.gsub(' ', '-'),             # Hyphens
        title.gsub(/[^\w\s\-]/, ''),      # Minimal sanitization
        sanitize_filename(title).downcase, # Lowercase underscore
        title.downcase.gsub(' ', '-')      # Lowercase hyphen
      ].uniq
      
      variants.each do |v|
        path = File.join(@project_path, "#{v}.md")
        Rails.logger.info "RedmineSubwikifiles: Checking existence of #{path}"
        return path if File.exist?(path)
      end
      
      Rails.logger.info "RedmineSubwikifiles: Resolution failed for title '#{title}'. Checked: #{variants.map { |v| File.join(@project_path, "#{v}.md") }.join(', ')}"
      nil
    end

    def self.sanitize_filename(title)
      # Replace spaces with underscores, remove special chars
      # Keep only alphanumeric, underscores, and hyphens
      title.gsub(' ', '_').gsub(/[^\w\-]/, '')
    end

    private

    def sanitize_filename(title)
      self.class.sanitize_filename(title)
    end
  end
end
