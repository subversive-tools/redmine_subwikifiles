module RedmineSubwikifiles
  # Provides a high-level interface to the Git filesystem backend.
  # Handles repository initialization, commits, renames, and deletions.
  class GitBackend
    def initialize(project)
      @project = project
      # Base path from settings or default
      @base_dir = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
      
      # Use FileStorage for consistent path resolution (respects .project metadata)
      @repo_path = FileStorage.new(project).project_path
      
      init_repo unless File.exist?(File.join(@repo_path, '.git'))
    end

    def commit(title, author:, message:)
      # We need to map title to filename again or pass the full path.
      # The patch passes full_title now.
      # But FileStorage logic for path is also needed here or replicated.
      # Ideally GitBackend should rely on relative path from repo root.
      
      # title here is "Parent/Child" (full_title from patch)
      # We need to sanitize it exactly as FileStorage does to get the filename
      # But FileStorage is responsible for writing. GitBackend should just add the file.
      
      # Replicate sanitization logic or use FileStorage to get path?
      # Using FileStorage is cleaner but might be circular if not careful.
      # Let's just replicate the simple logic:
      # sanitization: replace spaces with underscores, remove weird chars.
      # BUT, since we have full_title "Parent/Child", we split and sanitize each part?
      # FileStorage logic: sanitizes the WHOLE string. 
      # sanitized = title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      # This preserves slashes.
      
      file_rel_path = "#{title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')}.md"
      
      run_git('add', file_rel_path)
      
      # Author format: "Name <email>"
      author_str = "#{author.firstname} #{author.lastname} <#{author.mail}>"
      
      run_git('commit', '-m', message, 
              '--author', author_str,
              '--allow-empty-message')
    rescue => e
      Rails.logger.error("RedmineSubwikifiles: Git commit failed: #{e.message}")
    end
    
    def rename(old_title, new_title, author:, message:)
      old_sanitized = old_title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      new_sanitized = new_title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      
      old_file = "#{old_sanitized}.md"
      new_file = "#{new_sanitized}.md"
      
      # Git mv to rename
      run_git('mv', old_file, new_file)
      run_git('commit', '-m', message, '--author', "#{author.firstname} #{author.lastname} <#{author.mail}>")
      
      Rails.logger.info "RedmineSubwikifiles: Renamed #{old_file} to #{new_file} in Git"
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Git rename failed: #{e.message}"
      raise
    end
    
    def delete(title, author:, message:)
      sanitized = title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      filename = "#{sanitized}.md"
      
      # Git rm to delete
      run_git('rm', filename)
      run_git('commit', '-m', message, '--author', "#{author.firstname} #{author.lastname} <#{author.mail}>")
      
      Rails.logger.info "RedmineSubwikifiles: Deleted #{filename} from Git"
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Git delete failed: #{e.message}"
      raise
    end
    
    # Detect changes in the git repo that haven't been synced to Redmine
    # Returns: { renamed: [[old, new]], deleted: [files], modified: [files], added: [files] }
    def detect_changes
      changes = { renamed: [], deleted: [], modified: [], added: [] }
      
      # Get git status in porcelain format for easy parsing
      # Note: renames are only detected if files are staged first
      status_output = run_git('status', '--porcelain')
      
      status_output.each_line do |line|
        line = line.strip
        next if line.empty?
        
        status = line[0..1]
        files = line[3..-1]
        
        case status.strip
        when 'R', 'RM'  # Renamed (with or without modifications)
          # Format: "R  old.md -> new.md"
          old_file, new_file = files.split(' -> ').map(&:strip)
          changes[:renamed] << [old_file, new_file] if old_file && new_file
        when 'D'  # Deleted
          changes[:deleted] << files
        when 'M', 'MM', 'MD'  # Modified
          changes[:modified] << files
        when '??', 'A'  # New/Added
          changes[:added] << files
        end
      end
      
      changes
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to detect git changes: #{e.message}"
      { renamed: [], deleted: [], modified: [], added: [] }
    end
    
    def last_commit_author(file_path)
      # file_path is relative to repo root, e.g. "Space_Test.md"
      # We need to ensure it's safe and exists
      return nil unless file_path
      
      Rails.logger.info "RedmineSubwikifiles: Getting last commit author for file: #{file_path}"
      
      # Use git log to get the last author name
      # %an = author name
      author = run_git('log', '-1', '--format=%an', '--', file_path).strip
      
      Rails.logger.info "RedmineSubwikifiles: Author for #{file_path}: '#{author}'"
      
      return author.empty? ? nil : author
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to get last commit author for #{file_path}: #{e.message}"
      nil
    end
    
    # Public method for running git commands (used by GitSync)
    def run_git(*args)
      # -C <path> runs git as if started in <path>
      cmd = ['git', '-C', @repo_path] + args
      stdout, stderr, status = Open3.capture3(*cmd)
      
      unless status.success?
        # Check if it is "nothing to commit" which is fine
        if args.include?('commit') && (stdout.include?('nothing to commit') || stderr.include?('nothing to commit'))
          return stdout
        end
        raise "Git command failed: #{args.join(' ')}\nSTDOUT: #{stdout}\nSTDERR: #{stderr}"
      end
      
      stdout
    end
    
    private

    def init_repo
      FileUtils.mkdir_p(@repo_path)
      run_git('init')
      
      # Configure user for this repo to avoid "Committer identity unknown" error
      # This is local to the repo, so it doesn't affect global git config
      run_git('config', 'user.email', 'redmine@example.com')
      run_git('config', 'user.name', 'Redmine')
    end
  end
end
