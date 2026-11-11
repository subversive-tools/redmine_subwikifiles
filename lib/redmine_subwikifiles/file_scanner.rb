module RedmineSubwikifiles
  # Scans project directories for files that are not yet registered in Redmine.
  # Handles both Markdown files (potential wiki pages) and other file types (potential attachments).
  class FileScanner
    attr_reader :project
    
    def initialize(project)
      @project = project
    end
    
    # Scans the project directory for files that do not have associated WikiPages or attachments in Redmine.
    # @return [Hash] A hash containing lists of :orphaned and :locked files.
    def scan_for_new_files
      return { orphaned: [], locked: [] } unless plugin_enabled?
      
      project_path = FileStorage.new(project).project_path
      return { orphaned: [], locked: [] } unless Dir.exist?(project_path)
      
      orphaned_files = []
      locked_files = []
      
      # Get all files in project directory (flat structure)
      Dir.glob(File.join(project_path, "*")).each do |file_path|
        next if File.directory?(file_path)
        
        filename = File.basename(file_path)
        is_md = filename.end_with?(".md")
        base_name = is_md ? File.basename(filename, ".md") : filename
        
        # Use titleized version for matching with Redmine wiki titles
        title = Wiki.titleize(base_name)
        Rails.logger.info "RedmineSubwikifiles: Scanning #{filename}, title: #{title}"
        
        # Skip if WikiPage already exists (for .md files)
        if is_md && project.wiki && (page = project.wiki.pages.find_by(title: title))
          Rails.logger.info "RedmineSubwikifiles: Start skip - Page exists: #{title} (ID: #{page.id})"
          next
        end
        
        # Skip if already attached to Wiki pages or Project (for non-md files)
        already_attached = project.attachments.where(filename: filename).exists?
        if !already_attached && project.wiki
          already_attached = Attachment.where(container: project.wiki.pages, filename: filename).exists?
        end
        
        if !is_md && already_attached
          next
        end
        
        # Check if file is locked
        if FileLockChecker.locked?(file_path)
          locked_files << base_name
          Rails.logger.info "RedmineSubwikifiles: Skipping locked file: #{filename}"
          next
        end
        
        if is_md
          # Parse and validate frontmatter for MD files
          result = validate_file(file_path)
          Rails.logger.info "RedmineSubwikifiles: Validation result for #{filename}: #{result ? result[:valid] : 'nil'}"
          orphaned_files << result if result
        else
          # Add non-md files as valid orphans (of type attachment)
          orphaned_files << {
            path: file_path,
            filename: filename,
            type: 'attachment',
            valid: true,
            errors: []
          }
        end
      end
      
      { orphaned: orphaned_files, locked: locked_files }
    end
    
    private
    
    def validate_file(file_path)
      content = File.read(file_path)
      parsed = FrontmatterParser.parse(content)
      
      {
        path: file_path,
        filename: File.basename(file_path, ".md"),
        type: 'wiki',
        has_frontmatter: parsed[:metadata].present?,
        metadata: parsed[:metadata],
        content: parsed[:content],
        valid: true,
        errors: []
      }
    rescue => e
      {
        path: file_path,
        filename: File.basename(file_path, ".md"),
        type: 'wiki',
        valid: false,
        errors: [e.message]
      }
    end
    
    def plugin_enabled?
      return false unless project.wiki
      
      ProjectSync.enabled_for?(project)
    end
  end
end
