module RedmineSubwikifiles
  module WikiControllerPatch
    extend ActiveSupport::Concern
    
    included do
      Rails.logger.info "RedmineSubwikifiles: WikiControllerPatch included in #{self.name}"
      before_action :sync_from_filesystem, only: [:index, :show, :edit]
      before_action :check_file_consistency, only: [:show, :edit]
    end
    
    def sync_from_filesystem
      @project ||= Project.find_by(identifier: params[:project_id])
      return unless @project && @project.wiki

      if User.current.anonymous? && session[:user_id]
        User.current = User.find_by(id: session[:user_id])
      end

      return unless User.current.allowed_to?(:edit_wiki_pages, @project)
      
      # Project-level sync (Git changes, folder renames, import of new files)
      result = RedmineSubwikifiles::ProjectSync.new(@project).sync_project_files
      
      # Show locked files info
      if result[:locked].any?
        flash.now[:notice] = I18n.t(
          'redmine_subwikifiles.file_sync.locked_files',
          count: result[:locked].count,
          files: result[:locked].join(', ')
        )
      end
      
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
        
        flash.now[:notice] = msgs.join("<br>").html_safe
      end
      
      # EXPERIMENTAL: placeholder parent pages created for missing parents
      if result[:placeholders].any?
        flash.now[:warning] = I18n.t('redmine_subwikifiles.file_sync.placeholders_created',
                                 count: result[:placeholders].count,
                                 pages: result[:placeholders].map { |t| CGI.escapeHTML(t) }.join(', ')).html_safe
      end
      
      manual_orphans = result[:manual_orphans]
      
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
        
        # Keep the notice short: list the first entries only, the rest is in the sync popover
        max_listed = 10
        details_text = invalid_files_data.first(max_listed).map do |f|
          err = f[:errors].any? ? " (#{f[:errors].join(', ')})" : ""
          "<span class=\"orphan-file-entry\" data-file-id=\"#{f[:id]}\">#{CGI.escapeHTML(f[:file])}#{CGI.escapeHTML(err)}</span>"
        end.join(', ')
        if invalid_files_data.size > max_listed
          details_text += ' ' + CGI.escapeHTML(I18n.t('redmine_subwikifiles.file_sync.more_files', count: invalid_files_data.size - max_listed))
        end
        
        flash.now[:warning] = I18n.t(
          'redmine_subwikifiles.file_sync.pending_files',
          count: invalid_files_data.count,
          details: details_text
        ).html_safe
        # Store for JavaScript injection in ViewHook
        @pending_files_json = invalid_files_data.first(max_listed).to_json
      else
        @pending_files_json = "[]"
        # Clear any stale orphan warning from previous request
        search_term = I18n.t('redmine_subwikifiles.file_sync.pending_files', count: 0, details: '').split('0').first.strip
        flash.delete(:warning) if flash[:warning].to_s.include?(search_term)
      end
      
      # Reload page to ensure controller sees fresh data (e.g. content updated by GitSync)
      if @page
        if @page.persisted?
          @page.reload
          @page.content&.reload
        elsif @page.new_record?
          fresh_page = @project.wiki.pages.find_by(title: @page.title)
          @page = fresh_page if fresh_page
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
      file_path = storage.resolve_existing_path(@page.title)
      
      if file_path
        # File exists
        @associated_file_path = file_path
        
        # Check for Lock on EDIT action
        if action_name == 'edit' && RedmineSubwikifiles::FileLockChecker.locked?(file_path)
           flash.now[:error] = "⚠️ File '#{File.basename(file_path)}' is currently OPEN in an external editor (locked). Saving might overwrite external changes."
        end

        # Check content consistency (shared with the manual sync, respects conflict strategy)
        sync_result = RedmineSubwikifiles::ProjectSync.new(@project).sync_page(@page)
        Thread.current[:redmine_subwikifiles_just_updated] = true if sync_result == :updated

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
      end
    end
  end
end
