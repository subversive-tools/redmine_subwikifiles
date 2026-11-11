# Handles advanced file operations like folder assignment, orphan file importing, and attachment synchronization.
class SubwikifilesController < ApplicationController
  before_action :find_project
  before_action :authorize_global, only: [:folder_prompt, :assign_folder, :create_subproject_from_folder, :orphan_folder]
  
  # Displays a list of unassigned folders to the user for potential subproject creation.
  # Used primarily for global (top-level) folder detection.
  def folder_prompt
    @scanner = RedmineSubwikifiles::FolderScanner.new(@project)
    @all_unassigned = @scanner.scan_all_folders
    
    if @all_unassigned.empty?
      flash[:notice] = l('redmine_subwikifiles.no_unassigned_folders')
      if @project
        redirect_to project_wiki_path(@project)
      else
        redirect_to projects_path
      end
    else
      @folder = @all_unassigned.first
    end
  end
  
  # Processes the user's choice for an unassigned folder.
  # Delegates to the appropriate AJAX endpoint logic.
  def assign_folder
    folder_path = params[:folder_path]
    folder_name = params[:folder_name]
    action_type = params[:action_type]
    
    case action_type
    when 'subproject'
      result = do_create_subproject(folder_name, folder_path)
      if result[:success]
        flash[:notice] = l('redmine_subwikifiles.folder_sync.subproject_created', name: folder_name)
        redirect_to project_path(result[:project])
      else
        flash[:error] = result[:error]
        redirect_to_folder_prompt
      end
    when 'orphan'
      result = do_orphan_folder(folder_name, folder_path)
      if result[:success]
        flash[:notice] = l('redmine_subwikifiles.folder_sync.folder_orphaned', name: folder_name)
      else
        flash[:error] = result[:error]
      end
      redirect_to_folder_prompt
    else
      flash[:error] = l('redmine_subwikifiles.invalid_action')
      redirect_to_folder_prompt
    end
  end
  
  # Imports orphan files as wiki pages (AJAX).
  def fix_frontmatter
    unless User.current.allowed_to?(:edit_wiki_pages, @project)
      render json: { error: "Permission denied" }, status: :forbidden
      return
    end
    
    file_names = params[:files] || []
    parent_page_id = params[:page_id]
    
    if file_names.empty?
      render json: { error: "No files specified" }, status: :bad_request
      return
    end
    
    # Find parent page if specified
    parent_page_title = nil
    if parent_page_id.present? && @project.wiki
      Rails.logger.info "RedmineSubwikifiles: fix_frontmatter - page_id param: #{parent_page_id}"
      parent_page = @project.wiki.pages.find_by(id: parent_page_id) || 
                    @project.wiki.pages.find_by(title: parent_page_id)
      
      if parent_page
        parent_page_title = parent_page.title
        Rails.logger.info "RedmineSubwikifiles: fix_frontmatter - Parent page found: #{parent_page_title} (ID: #{parent_page.id})"
      end
    end
    
    storage = RedmineSubwikifiles::FileStorage.new(@project)
    
    orphan_data = file_names.map do |name|
      file_path = File.join(storage.project_path, "#{name}.md")
      
      unless File.exist?(file_path)
        Rails.logger.warn "RedmineSubwikifiles: File not found: #{file_path}"
        next nil
      end
      
      raw_content = File.read(file_path, encoding: 'UTF-8')
      parsed = RedmineSubwikifiles::FrontmatterParser.parse(raw_content)
      metadata = parsed[:metadata].is_a?(Hash) ? parsed[:metadata].dup : {}
      content = parsed[:content].to_s.strip.presence || '(empty content)'
      
      if parent_page_title.present? && !metadata['parent']
        metadata['parent'] = parent_page_title
        Rails.logger.info "RedmineSubwikifiles: fix_frontmatter - Assigned parent '#{parent_page_title}' to '#{name}'"
      end
      
      {
        filename: name,
        path: file_path,
        content: content,
        metadata: metadata,
        valid: true
      }
    end.compact
    
    if orphan_data.empty?
      render json: { error: "No valid files to import" }, status: :bad_request
      return
    end
    
    Rails.logger.info "RedmineSubwikifiles: Importing #{orphan_data.length} orphan files via fix_frontmatter"
    importer = RedmineSubwikifiles::WikiImporter.new(@project)
    import_result = importer.import_files(orphan_data)
    
    render json: {
      fixed: import_result[:imported],
      failed: import_result[:skipped].map { |s| { file: s[:file], error: s[:errors].join(', ') } }
    }
  end
  
  # Import a file as an attachment (AJAX).
  def attach_file
    unless User.current.allowed_to?(:edit_wiki_pages, @project)
      render json: { error: "Permission denied" }, status: :forbidden
      return
    end
    
    file_name = params[:file]
    if file_name.blank?
      render json: { error: "No file specified" }, status: :bad_request
      return
    end
    
    # Identify container
    container = nil
    if params[:page_id].present? && @project.wiki
       container = @project.wiki.pages.find_by(id: params[:page_id]) || 
                   @project.wiki.pages.find_by(title: params[:page_id])
    end
    
    result = RedmineSubwikifiles::AttachmentImporter.attach(@project, file_name, container)
    if result[:success]
      render json: { success: true, file: file_name, container: result[:container].class.name }
    elsif result[:error].to_s.start_with?('File not found')
      render json: { error: result[:error] }, status: :not_found
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # Restore a missing file from wiki content.
  def restore_file
    unless User.current.allowed_to?(:edit_wiki_pages, @project)
      render_403
      return
    end

    title = params[:title]
    page = @project.wiki.pages.find_by(title: title)
    
    if page && page.content
      page.content.write_to_md_file_with_frontmatter
      storage = RedmineSubwikifiles::FileStorage.new(@project)
      if page.content.subwikifiles_write_error.nil? && storage.file_exists?(title)
        flash[:notice] = I18n.t('redmine_subwikifiles.notices.file_restored', file: "#{title}.md")
      else
        flash[:error] = I18n.t('redmine_subwikifiles.errors.file_restore_failed',
                               file: storage.file_path(title),
                               error: page.content.subwikifiles_write_error || '-')
      end
    else
      flash[:error] = I18n.t('redmine_subwikifiles.errors.page_not_found', page: title)
    end
    
    redirect_back(fallback_location: project_wiki_path(@project, title))
  end

  # Dry-run plan of all sync actions around the current page (JSON for the sync popover).
  def plan
    return render_403 unless @project && User.current.allowed_to?(:edit_wiki_pages, @project)

    plan = build_sync_plan
    render json: plan.as_json_for(view_context)
  end

  # Automatic sync (called in the background after a wiki page loaded):
  # applies all unambiguous actions in the whole tree, returns the remaining plan (JSON).
  def auto
    return render_403 unless @project && User.current.allowed_to?(:edit_wiki_pages, @project)

    # Throttle: the automatic run happens at most once per AUTO_INTERVAL per project tree
    # (across all users); otherwise only the read-only plan is returned.
    stats = Hash.new(0)
    stats[:errors] = []
    throttled = !RedmineSubwikifiles.throttle_slot?("auto/#{@project.root.id}")
    stats = build_sync_plan.apply('tree', {}, only_certain: true) unless throttled
    done = stats[:to_wiki] + stats[:to_file] + stats[:created] + stats[:imported]
    plan = build_sync_plan
    render json: plan.as_json_for(view_context).merge(
      auto: { done: done, to_wiki: stats[:to_wiki], to_file: stats[:to_file] + stats[:created],
              imported: stats[:imported], errors: stats[:errors], throttled: throttled,
              current_page_changed: stats[:current_page_changed] }
    )
  end

  # Applies the plan for a scope. Conflicts/deleted files use params[:decisions][key].
  def apply
    return render_403 unless @project && User.current.allowed_to?(:edit_wiki_pages, @project)

    scope = RedmineSubwikifiles::SyncPlan::SCOPES.include?(params[:scope]) ? params[:scope] : 'page'
    decisions = params[:decisions].respond_to?(:to_unsafe_h) ? params[:decisions].to_unsafe_h : (params[:decisions] || {})
    stats = build_sync_plan.apply(scope, decisions.to_h.transform_values(&:to_s))

    parts = []
    parts << "↓ #{stats[:to_wiki]}" if stats[:to_wiki] > 0
    parts << "↑ #{stats[:to_file] + stats[:created]}" if stats[:to_file] + stats[:created] > 0
    parts << "+ #{stats[:imported]}" if stats[:imported] > 0
    parts << "📎 #{stats[:attached]}" if stats[:attached] > 0
    parts << l('redmine_subwikifiles.sync.deleted_pages', count: stats[:deleted_pages]) if stats[:deleted_pages] > 0
    parts << l('redmine_subwikifiles.sync.deleted_files', count: stats[:deleted_files]) if stats[:deleted_files] > 0
    msg = l('redmine_subwikifiles.sync.applied', changes: parts.any? ? parts.join(' · ') : '0')
    msg += ' ' + l('redmine_subwikifiles.sync.skipped', count: stats[:skipped]) if stats[:skipped] > 0
    msg += ' ' + l('redmine_subwikifiles.sync.placeholders', count: stats[:placeholders]) if stats[:placeholders] > 0
    flash[:notice] = msg

    if stats[:errors].any?
      shown = stats[:errors].first(10).map { |e| ERB::Util.html_escape(e) }
      shown << "… (+#{stats[:errors].size - 10})" if stats[:errors].size > 10
      flash[:error] = ERB::Util.html_escape(l('redmine_subwikifiles.sync.errors', count: stats[:errors].size)) +
                      '<br>'.html_safe + shown.join('<br>').html_safe
    end

    redirect_back(fallback_location: project_wiki_index_path(@project))
  end
  
  # Create subproject from folder (AJAX).
  def create_subproject_from_folder
    folder_name = params[:folder_name]
    folder_path = params[:folder_path]
    
    if folder_name.blank? || folder_path.blank?
      render json: { error: "Missing folder information" }, status: :bad_request
      return
    end
    
    result = do_create_subproject(folder_name, folder_path)
    
    if result[:success]
      render json: { success: true, folder: folder_name, project_id: result[:project].identifier }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  # Move folder to _orphaned (AJAX).
  def orphan_folder
    folder_name = params[:folder_name]
    folder_path = params[:folder_path]
    
    if folder_name.blank? || folder_path.blank?
      render json: { error: "Missing folder information" }, status: :bad_request
      return
    end
    
    result = do_orphan_folder(folder_name, folder_path)
    
    if result[:success]
      render json: { success: true, folder: folder_name }
    else
      render json: { error: result[:error] }, status: result[:status] || :internal_server_error
    end
  end
  
  private
  
  def build_sync_plan
    page = params[:page].present? && @project.wiki ? @project.wiki.find_page(params[:page]) : nil
    RedmineSubwikifiles::SyncPlan.new(@project, page: page).build
  end

  def find_project
    if params[:project_id].present?
      @project = Project.find(params[:project_id])
    else
      @project = nil
    end
  rescue ActiveRecord::RecordNotFound
    render_404
  end
  
  def authorize_global
    if @project
      return true if User.current.allowed_to?(:manage_subwikifiles, @project) || User.current.admin?
    else
      return true if User.current.admin? || User.current.allowed_to?(:add_project, nil, global: true)
    end
    deny_access
  end

  def redirect_to_folder_prompt
    if @project
      redirect_to project_subwikifiles_folder_prompt_path(@project)
    else
      redirect_to global_subwikifiles_folder_prompt_path
    end
  end
  
  # Shared logic for creating a subproject from a folder.
  # Returns { success: true, project: <Project> } or { success: false, error: "..." }
  def do_create_subproject(folder_name, folder_path)
    # Sanitize folder name to valid identifier
    identifier = folder_name.downcase
                            .gsub(/[^a-z0-9\-]/, '-')
                            .gsub(/\-+/, '-')
                            .gsub(/^\-|\-$/, '')
    
    # Ensure identifier is not empty
    identifier = "folder-#{Time.now.to_i}" if identifier.blank?
    
    # Ensure unique identifier
    base_identifier = identifier
    counter = 1
    while Project.exists?(identifier: identifier)
      identifier = "#{base_identifier}-#{counter}"
      counter += 1
    end
    
    subproject = Project.new(
      name: folder_name,
      identifier: identifier,
      parent: @project
    )
    
    # Inherit settings from parent
    if @project
      subproject.is_public = @project.is_public
      subproject.inherit_members = true
    end
    
    unless subproject.save
      return { success: false, error: subproject.errors.full_messages.join(', ') }
    end
    
    # Inherit modules if parent exists
    if @project
      subproject.enabled_module_names = @project.enabled_module_names | ['wiki', 'redmine_subwikifiles']
    else
      # Fallback for top-level projects
      subproject.enabled_module_names = ['wiki', 'redmine_subwikifiles']
    end
    
    # Create .project metadata file in folder (keeps original folder name)
    RedmineSubwikifiles::FileStorage.write_project_metadata(folder_path, subproject)
    
    # Initialize Git repo
    begin
      RedmineSubwikifiles::GitBackend.new(subproject)
      Rails.logger.info "RedmineSubwikifiles: Initialized Git repo for #{subproject.identifier}"
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to init Git: #{e.message}"
    end
    
    Rails.logger.info "RedmineSubwikifiles: Created subproject '#{folder_name}' (#{identifier}) from folder"
    { success: true, project: subproject }
  end
  
  # Shared logic for moving a folder to _orphaned.
  # Returns { success: true } or { success: false, error: "...", status: :symbol }
  def do_orphan_folder(folder_name, folder_path)
    unless File.directory?(folder_path)
      return { success: false, error: "Folder not found: #{folder_name}", status: :not_found }
    end
    
    # Get project path
    if @project
      storage = RedmineSubwikifiles::FileStorage.new(@project)
      project_path = storage.project_path
    else
      project_path = RedmineSubwikifiles.base_path
    end
    
    # Create _orphaned directory if needed
    orphaned_dir = File.join(project_path, '_orphaned')
    FileUtils.mkdir_p(orphaned_dir) unless File.directory?(orphaned_dir)
    
    # Target path
    target_path = File.join(orphaned_dir, folder_name)
    
    # Handle name collision
    if File.exist?(target_path)
      timestamp = Time.now.strftime('%Y%m%d%H%M%S')
      target_path = File.join(orphaned_dir, "#{folder_name}_#{timestamp}")
    end
    
    begin
      FileUtils.mv(folder_path, target_path)
      Rails.logger.info "RedmineSubwikifiles: Moved folder '#{folder_name}' to _orphaned"
      { success: true }
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to move folder to _orphaned: #{e.message}"
      { success: false, error: e.message }
    end
  end
end
