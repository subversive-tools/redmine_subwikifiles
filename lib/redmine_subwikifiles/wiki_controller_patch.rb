module RedmineSubwikifiles
  module WikiControllerPatch
    extend ActiveSupport::Concern
    
    included do
      Rails.logger.info "RedmineSubwikifiles: WikiControllerPatch included in #{self.name}"
      before_action :sync_from_filesystem, only: [:index, :show, :edit]
      before_action :check_file_consistency, only: [:show, :edit]
    end
    
    def sync_from_filesystem
      Rails.logger.info "RedmineSubwikifiles: sync_from_filesystem called, params[:project_id] = #{params[:project_id]}"
      
      # Load @project if not already set (before_action may run before WikiController's find_project)
      unless @project
        @project = Project.find_by(identifier: params[:project_id])
        Rails.logger.info "Redmine Subwikifiles: Loaded project from params: #{@project&.identifier || 'nil'}"
      end
      
      Rails.logger.info "RedmineSubwikifiles: sync_from_filesystem called for project: #{@project&.identifier || 'NO PROJECT'}"
      
      return unless @project
      return unless @project.wiki
      
      # Force user hydration if anonymous but user_id exists in session
      if User.current.anonymous? && session[:user_id]
        User.current = User.find_by(id: session[:user_id])
        Rails.logger.info "RedmineSubwikifiles: Hydrated User.current: #{User.current&.login} (ID: #{User.current&.id})"
      end
      
      Rails.logger.info "RedmineSubwikifiles: Checking permissions for user: #{User.current.login} (ID: #{User.current.id})"
      
      # Only sync for users with edit permissions
      can_edit = User.current.allowed_to?(:edit_wiki_pages, @project)
      Rails.logger.info "RedmineSubwikifiles: Permission check (edit_wiki_pages): #{can_edit}"
      return unless can_edit
      
      # Sync filesystem moves/renames/deletes first
      Rails.logger.info "RedmineSubwikifiles: Calling GitSync..."
      begin
        sync = RedmineSubwikifiles::GitSync.new(@project)
        sync.sync_from_filesystem
      rescue => e
        Rails.logger.error "RedmineSubwikifiles: GitSync failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end

      # Sync folder renames to Redmine project names (respects conflict_strategy)
      begin
        Rails.logger.info "RedmineSubwikifiles: Calling sync_folder_renames_to_redmine for #{@project&.identifier}"
        sync_folder_renames_to_redmine(@project)
      rescue => e
        Rails.logger.error "RedmineSubwikifiles: Folder rename sync failed: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end

      Rails.logger.info "RedmineSubwikifiles: Starting file scan..."
      
      # Scan for new files (orphans)
      scanner = FileScanner.new(@project)
      scan_result = scanner.scan_for_new_files
      
      # Show locked files info
      if scan_result[:locked].any?
        flash[:notice] = I18n.t(
          'redmine_subwikifiles.file_sync.locked_files',
          count: scan_result[:locked].count,
          files: scan_result[:locked].join(', ')
        )
      end
      
      Rails.logger.info "RedmineSubwikifiles: Found #{scan_result[:orphaned].count} new files, #{scan_result[:locked].count} locked"
      
      # Separate auto-importable wiki pages from other orphans
      # Auto-import ONLY files that have valid frontmatter
      to_import = scan_result[:orphaned].select { |f| f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter] }
      
      # Manual orphans: Files without frontmatter + attachments + invalid files
      manual_orphans = scan_result[:orphaned].reject { |f| f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter] }
      
      Rails.logger.info "RedmineSubwikifiles: #{to_import.count} to import, #{manual_orphans.count} manual orphans"
      Rails.logger.info "RedmineSubwikifiles: Manual orphans details: #{manual_orphans.inspect}"
      
      # Import valid wiki pages
      if to_import.any?
        importer = RedmineSubwikifiles::WikiImporter.new(@project)
        result = importer.import_files(to_import)
        
        # Add successfully imported count to flash
        if result[:imported].any? || result[:renamed].any?
          msgs = []
          
          if result[:imported].any?
            msgs << I18n.t(
              'redmine_subwikifiles.file_sync.imported_count',
              count: result[:imported].count,
              pages: result[:imported].join(', ')
            )
          end
          
          if result[:renamed].any?
            details = result[:renamed].map { |r| "'#{r[:old_title]}' -> '#{r[:new_title]}'" }.join(', ')
            msgs << I18n.t(
              'redmine_subwikifiles.file_sync.renamed_count',
              count: result[:renamed].count,
              details: details
            )
          end
          
          flash[:notice] = msgs.join("<br>").html_safe
        end
        
        # Add failed imports (still orphans) to manual_orphans
        manual_orphans += result[:skipped]
      end
      
      # Handle manual orphans (show warning and interactive buttons)
      if manual_orphans.any?
        invalid_files_data = manual_orphans.map do |o|
          filename = o[:filename] || o[:file]
          path = o[:path] || ""
          errors = o[:errors] ? o[:errors].dup : []
          if o[:type] == 'wiki' && !o[:has_frontmatter] && o[:valid]
             errors << I18n.t('redmine_subwikifiles.file_sync.missing_frontmatter')
          end
          
          # Use a safe ID for DOM targeting
          safe_id = Base64.strict_encode64(filename.to_s).gsub(/[^a-zA-Z0-9]/, '')
          
          {
            file: filename,
            id: safe_id,
            type: (filename.to_s.end_with?(".md") || path.to_s.end_with?(".md")) ? 'wiki' : 'attachment',
            errors: errors
          }
        end
        
        details_text = invalid_files_data.map do |f|
          err = f[:errors].any? ? " (#{f[:errors].join(', ')})" : ""
          "<span class=\"orphan-file-entry\" data-file-id=\"#{f[:id]}\">#{CGI.escapeHTML(f[:file])}#{CGI.escapeHTML(err)}</span>"
        end.join(', ')
        
        flash[:warning] = I18n.t(
          'redmine_subwikifiles.file_sync.pending_files',
          count: invalid_files_data.count,
          details: details_text
        ).html_safe
        # Store for JavaScript injection in ViewHook
        @pending_files_json = invalid_files_data.to_json
      else
        @pending_files_json = "[]"
        # Clear any stale orphan warning from previous request
        search_term = I18n.t('redmine_subwikifiles.file_sync.pending_files', count: 0, details: '').split('0').first.strip
        flash.delete(:warning) if flash[:warning].to_s.include?(search_term)
      end
      
      # Reload page to ensure controller sees fresh data (e.g. content updated by GitSync)
      if @page
        if @page.persisted?
          Rails.logger.info "RedmineSubwikifiles: DEBUG: Reloading page #{@page.title}"
          @page.reload
          @page.content&.reload
        elsif @page.new_record?
          # It was new, but maybe GitSync created it?
          fresh_page = @project.wiki.pages.find_by(title: @page.title)
          if fresh_page
            Rails.logger.info "RedmineSubwikifiles: DEBUG: Page #{@page.title} was created by sync, loading it"
            @page = fresh_page
          end
        end
      end
      
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Sync error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end

    def check_file_consistency
      return unless @page && @page.persisted?
      return unless User.current.allowed_to?(:edit_wiki_pages, @project) # Only check for editors

      storage = RedmineSubwikifiles::FileStorage.new(@project)
      
      # Check for file existence
      file_path = storage.send(:resolve_existing_path, @page.title)
      
      if file_path
        # File exists
        @associated_file_path = file_path
        
        # Check for Lock on EDIT action
        if action_name == 'edit' && RedmineSubwikifiles::FileLockChecker.locked?(file_path)
           flash.now[:error] = "⚠️ File '#{File.basename(file_path)}' is currently OPEN in an external editor (locked). Saving might overwrite external changes."
        end

        # Check content consistency
        file_content, _ = storage.read(@page.title)
        
        # Parse frontmatter to compare only content body
        parsed = RedmineSubwikifiles::FrontmatterParser.parse(file_content)
        content_only = parsed[:content]
        
        if file_content && content_only != @page.content.text
          # Content changed - Auto-update
          
          # Get author from git
          git_author = nil
          begin
             backend = RedmineSubwikifiles::GitBackend.new(@project)
             # file_path is absolute, need relative for git log
             # GitBackend usually expects relative? 
             # let's look at last_commit_author implementation: it uses passed path.
             # If we pass absolute path to git log -- <path>, it works fine.
             git_author = backend.last_commit_author(file_path)
          rescue => e
             Rails.logger.warn "RedmineSubwikifiles: Could not get git author: #{e.message}"
          end
          
          author_text = git_author ? " (Author: #{git_author})" : ""
          
          @page.content.text = content_only
          @page.content.comments = "Auto-updated from file '#{@page.title}.md'#{author_text}"
          
          if @page.save
             Thread.current[:redmine_subwikifiles_just_updated] = true
          end
        end

        # Check for flag set by checking content above OR by WikiContentPatch (after_find)
        if Thread.current[:redmine_subwikifiles_just_updated]
            # Only show flash if user edited this page recently (2 hours)
            # This prevents annoying method for users just viewing
            # We must exclude the current auto-update version (and any past auto-updates)
            # so we check for manual edits only.
            recent_edit = @page.content.versions.where(author_id: User.current.id)
                               .where('updated_on >= ?', 2.hours.ago)
                               .where.not("comments LIKE ?", "Updated from filesystem%")
                               .exists?
                               
            if recent_edit
              # User requested to show this message only once per update.
              # We use the session to track the last notified timestamp for this page.
              session_key = "redmine_subwikifiles_notified_time_#{@page.id}"
              current_updated_on = @page.content.updated_on.to_i
              
              if session[session_key] != current_updated_on
                flash.now[:notice] = "Wiki content auto-updated from file '#{@page.title}.md'."
                session[session_key] = current_updated_on
              end
            end
            
            # Clear flag to avoid leaking
            Thread.current[:redmine_subwikifiles_just_updated] = nil
            
            @page.reload
        end
      else
        # File missing - Only warn on SHOW (Save will create it)
        if action_name == 'show'
          restore_url = url_for(controller: 'subwikifiles', action: 'restore_file', project_id: @project.identifier, title: @page.title)
          msg = I18n.t('redmine_subwikifiles.file_sync.file_missing', file: "#{@page.title}.md") + " "
          msg << "<a href='#{restore_url}' class='icon icon-add' data-method='post'>#{I18n.t('redmine_subwikifiles.actions.restore_file')}</a>"
          flash.now[:error] = msg.html_safe
        end
      end
    end

    private

    # Detect folder renames in the filesystem and sync them to Redmine project names.
    # Only applies when conflict_strategy is 'file_wins' or 'manual'.
    # With 'db_wins', the filesystem is expected to follow Redmine, not vice versa.
    def sync_folder_renames_to_redmine(project)
      conflict_strategy = Setting.plugin_redmine_subwikifiles['conflict_strategy'] || 'file_wins'
      return if conflict_strategy == 'db_wins'

      sync_single_project_name(project)

      # Also check direct subprojects
      project.children.active.each do |child|
        next unless child.module_enabled?(:redmine_subwikifiles) || Setting.plugin_redmine_subwikifiles['enabled']
        sync_single_project_name(child)
      end
    end

    # For a single project: compare the actual folder name to the project name.
    # If different, update the project name in Redmine.
    def sync_single_project_name(project)
      storage = RedmineSubwikifiles::FileStorage.new(project)
      folder_path = storage.project_path
      Rails.logger.info "RedmineSubwikifiles: sync_single_project_name '#{project.identifier}': folder_path=#{folder_path}, exists=#{Dir.exist?(folder_path)}"
      return unless Dir.exist?(folder_path)

      folder_name = File.basename(folder_path)
      
      Rails.logger.info "RedmineSubwikifiles: sync_single_project_name '#{project.identifier}': folder_name='#{folder_name}', project.name='#{project.name}', match=#{folder_name == project.name}"
      # Nothing to do if names match
      return if folder_name == project.name

      Rails.logger.info "RedmineSubwikifiles: Folder rename detected for '#{project.identifier}': " \
                        "project name='#{project.name}', folder name='#{folder_name}'. Syncing to Redmine."

      # Update project name to match folder, suppress our own after_save callback
      Thread.current[:redmine_subwikifiles_syncing] = true
      begin
        project.name = folder_name
        if project.save
          Rails.logger.info "RedmineSubwikifiles: Updated project name to '#{folder_name}'"
          # Update .project metadata to keep it consistent
          RedmineSubwikifiles::FileStorage.write_project_metadata(folder_path, project)
        else
          Rails.logger.error "RedmineSubwikifiles: Failed to update project name: #{project.errors.full_messages.join(', ')}"
        end
      ensure
        Thread.current[:redmine_subwikifiles_syncing] = false
      end
    end
  end
end

