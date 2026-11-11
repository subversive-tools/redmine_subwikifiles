module RedmineSubwikifiles
  # Builds a dry-run plan of all sync actions around a wiki page / project and applies it.
  #
  # Every action is tagged with the scopes it belongs to:
  #   page   - the current page
  #   branch - the current page and all its child pages
  #   wiki   - all pages of the current project (+ new files in its folder)
  #   tree   - the current project and all active subprojects
  #
  # The direction is determined per action by SyncState (three-way comparison against Git);
  # only conflicts and deleted files need a decision.
  class SyncPlan
    SCOPES = %w[page branch wiki tree].freeze
    ACTIONABLE = %w[create_file to_file to_wiki conflict deleted page_deleted import pending attachment].freeze
    # Deletions are never automatic and default to 'skip'
    DELETION_KINDS = %w[deleted page_deleted].freeze

    Action = Struct.new(:key, :kind, :project, :page, :title, :fallback, :detail, :default,
                        :scopes, :file_info, :file_body, :file_path, :keyword_init => true) do
      def to_h_json(view)
        {
          key: key,
          kind: kind,
          project: project.name,
          project_id: project.identifier,
          title: title,
          url: page ? view.url_for(controller: '/wiki', action: 'show', project_id: project.identifier, id: page.title, only_path: true) : nil,
          fallback: fallback,
          detail: detail,
          default: default,
          scopes: scopes
        }
      end
    end

    attr_reader :project, :page, :user, :actions

    def initialize(project, page: nil, user: User.current)
      @project = project
      @page = page
      @user = user
      @actions = []
      @branch_ids = page ? [page.id] + page.descendants.map(&:id) : []
      @subprojects = project.descendants.active.to_a
    end

    def available
      {
        'page' => !page.nil?,
        'branch' => !page.nil? && @branch_ids.size > 1,
        'wiki' => true,
        'tree' => @subprojects.any?
      }
    end

    # Builds the full plan (all scopes). Read-only.
    def build
      RedmineSubwikifiles.without_auto_sync do
        ([project] + @subprojects).each { |p| plan_project(p) }
      end
      self
    end

    # Actions that can be applied without asking (unambiguous direction / target).
    # Everything else needs a decision in the popover.
    def certain?(a)
      case a.kind
      when 'create_file', 'to_file', 'import' then !a.fallback
      when 'to_wiki' then !a.fallback && RedmineSubwikifiles.conflict_strategy != 'db_wins'
      else false
      end
    end

    def count(scope)
      actions.count { |a| ACTIONABLE.include?(a.kind) && a.scopes.include?(scope) }
    end

    def as_json_for(view)
      {
        available: available,
        counts: SCOPES.map { |s| [s, count(s)] }.to_h,
        subprojects: @subprojects.size,
        branch_pages: @branch_ids.size,
        default_scope: default_scope,
        actions: actions.map { |a| a.to_h_json(view) }
      }
    end

    def default_scope
      SCOPES.find { |s| available[s] && count(s) > 0 } || (page ? 'page' : 'wiki')
    end

    # Applies all actions of a scope. decisions: { action_key => 'file'|'wiki'|'restore'|'skip' }
    # Returns stats hash.
    def apply(scope, decisions = {}, only_certain: false)
      stats = Hash.new(0)
      stats[:errors] = []
      selected = actions.select { |a| ACTIONABLE.include?(a.kind) && a.scopes.include?(scope) }
      selected = selected.select { |a| certain?(a) } if only_certain
      stats[:current_page_changed] = false

      selected.group_by(&:project).each do |proj, list|
        committed_paths = []
        imports = []

        list.each do |a|
          choice = decisions[a.key].presence || a.default
          op =
            case a.kind
            when 'create_file', 'to_file' then :write
            when 'to_wiki' then :read
            when 'conflict' then { 'file' => :read, 'wiki' => :write }[choice]
            when 'deleted' then { 'restore' => :write, 'delete_page' => :delete_page }[choice]
            when 'page_deleted' then { 'delete_file' => :delete_file, 'reimport' => :reimport }[choice]
            when 'import' then :import
            when 'pending' then choice == 'import' ? :import_plain : nil
            when 'attachment' then choice == 'attach' ? :attach : nil
            end

          case op
          when :write
            if write_file(a)
              stats[a.kind == 'create_file' || a.kind == 'deleted' ? :created : :to_file] += 1
            else
              stats[:errors] << "#{proj.name}/#{a.title}: #{a.page.content.subwikifiles_write_error}"
            end
          when :read
            if read_file(a)
              stats[:to_wiki] += 1
              stats[:current_page_changed] = true if @page && a.page&.id == @page.id
              committed_paths << a.file_path
            else
              stats[:errors] << "#{proj.name}/#{a.title}: #{a.page.content.errors.full_messages.join(', ')}"
            end
          when :import
            imports << a
          when :import_plain
            imports << plain_import_action(a, proj)
          when :reimport
            info = a.file_info.dup
            info[:metadata] = (info[:metadata] || {}).except('id', 'wiki_id')
            imports << Action.new(a.to_h.merge(file_info: info))
          when :delete_page
            title = a.page.title
            RedmineSubwikifiles.without_auto_sync { a.page.destroy }
            if a.page.destroyed?
              stats[:deleted_pages] += 1
              Rails.logger.info "RedmineSubwikifiles: Deleted wiki page '#{title}' (confirmed by #{user.login})"
            else
              stats[:errors] << "#{proj.name}/#{title}: page could not be deleted"
            end
          when :delete_file
            if delete_file(proj, a.file_info[:path])
              stats[:deleted_files] += 1
            else
              stats[:errors] << "#{proj.name}/#{a.title}: file could not be deleted"
            end
          when :attach
            container = proj.id == @project.id && @page ? @page : nil
            r = AttachmentImporter.attach(proj, a.title, container)
            if r[:success]
              stats[:attached] += 1
            else
              stats[:errors] << "#{proj.name}/#{a.title}: #{r[:error]}"
            end
          else
            stats[:skipped] += 1
          end
        end

        if imports.any?
          result = WikiImporter.new(proj).import_files(imports.map(&:file_info))
          stats[:imported] += result[:imported].size + result[:renamed].size
          stats[:placeholders] += result[:placeholders].size
          result[:skipped].each { |s| stats[:errors] << "#{proj.name}/#{s[:file]}: #{Array(s[:errors]).join(', ')}" }
        end

        commit_paths(proj, committed_paths) if committed_paths.any?
      rescue => e
        stats[:errors] << "#{proj.name}: #{e.message}"
        Rails.logger.error "RedmineSubwikifiles: apply failed for #{proj.identifier}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      end

      stats
    end

    def self.skip_reason(project, user)
      return :no_wiki unless project.wiki
      return :disabled unless ProjectSync.enabled_for?(project)
      return :no_permission unless user.allowed_to?(:edit_wiki_pages, project)
      nil
    end

    private

    def plan_project(proj)
      reason = self.class.skip_reason(proj, user)
      if reason
        add(kind: 'skipped', project: proj, title: proj.name, detail: reason.to_s, project_level: true)
        return
      end

      storage = FileStorage.new(proj)
      state = SyncState.new(proj, storage: storage)
      renamed_page_ids = []

      # New files in the project folder (only relevant for wiki/tree scope)
      scan = FileScanner.new(proj).scan_for_new_files
      scan[:locked].each { |f| add(kind: 'locked', project: proj, title: "#{f}.md", project_level: true) }
      scan[:orphaned].each do |f|
        name = f[:filename] || f[:file]
        if f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter] && WikiImporter.deleted_page_reference?(f[:metadata])
          # Page was deleted in Redmine, file still there -> deletion candidate
          add(kind: 'page_deleted', project: proj, title: "#{name}.md", default: 'skip', file_info: f, project_level: true)
        elsif f[:type] == 'wiki' && f[:valid] && f[:has_frontmatter]
          meta = f[:metadata] || {}
          detail = nil
          if meta['id'] && (renamed = proj.wiki.pages.find_by(id: meta['id']))
            detail = "rename:#{renamed.title}"
            renamed_page_ids << renamed.id
          elsif meta['parent'] && !proj.wiki.find_page(meta['parent'])
            detail = "placeholder:#{meta['parent']}"
          end
          add(kind: 'import', project: proj, title: "#{name}.md", detail: detail, file_info: f, project_level: true)
        elsif f[:type] == 'wiki' && f[:valid]
          # Markdown file without wiki header: import it (like the ✓ fix button), below the current page
          parent = proj.id == @project.id ? @page : nil
          add(kind: 'pending', project: proj, title: "#{name}.md", default: 'import',
              detail: parent ? "parent:#{parent.title}" : nil, file_info: f, project_level: true)
        elsif f[:type] == 'attachment'
          # Other file: attach it (like the ✓ fix button), to the current page or the wiki
          target = proj.id == @project.id ? @page : nil
          add(kind: 'attachment', project: proj, title: name, default: 'attach',
              detail: target ? "container:#{target.title}" : nil, file_info: f, project_level: true)
        else
          add(kind: 'error', project: proj, title: "#{name}.md", detail: Array(f[:errors]).join(', '), project_level: true)
        end
      end

      proj.wiki.pages.includes(:content).each do |pg|
        next if renamed_page_ids.include?(pg.id)
        content = pg.content
        next unless content
        r = state.classify(pg, content)
        next if r.state == :ok

        kind = r.state.to_s
        default =
          case r.state
          when :conflict then SyncState.conflict_default(r.file_path, content)
          when :deleted then 'skip'
          end
        add(kind: kind, project: proj, page: pg, title: pg.title, fallback: r.fallback,
            default: default, file_body: r.file_body, file_path: r.file_path)
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: planning failed for #{proj.identifier}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      add(kind: 'error', project: proj, title: proj.name, detail: e.message, project_level: true)
    end

    def add(kind:, project:, title:, page: nil, fallback: nil, detail: nil, default: nil,
            file_info: nil, file_body: nil, file_path: nil, project_level: false)
      scopes = ['tree']
      if project.id == @project.id
        scopes << 'wiki'
        if page && !project_level
          scopes << 'branch' if @branch_ids.include?(page.id)
          scopes << 'page' if @page && page.id == @page.id
        end
      end
      key = "p#{project.id}-#{page ? page.id : Digest::MD5.hexdigest(title.to_s)[0, 10]}"
      @actions << Action.new(key: key, kind: kind, project: project, page: page, title: title,
                             fallback: fallback, detail: detail, default: default, scopes: scopes,
                             file_info: file_info, file_body: file_body, file_path: file_path)
    end

    # File without wiki header -> import with an empty header (parent = current page, as the ✓ button does)
    def plain_import_action(action, proj)
      info = action.file_info.dup
      raw = File.read(info[:path], encoding: 'UTF-8')
      meta = {}
      meta['parent'] = @page.title if proj.id == @project.id && @page
      info.merge!(has_frontmatter: true, metadata: meta, content: raw.presence || '(empty content)')
      Action.new(action.to_h.merge(file_info: info))
    end

    # Confirmed deletion of a file: removed from disk and committed (stays in Git history)
    def delete_file(proj, path)
      return false unless path && File.file?(path)
      File.delete(path)
      backend = GitBackend.new(proj)
      rel = SyncState.new(proj).relative(path)
      backend.run_git('add', '-A', '--', rel)
      author = "#{user.firstname} #{user.lastname} <#{user.mail.presence || 'redmine@example.com'}>"
      backend.run_git('commit', '-m', "Deleted #{rel} (confirmed in Redmine)", '--author', author) rescue nil
      Rails.logger.info "RedmineSubwikifiles: Deleted file '#{path}' (confirmed by #{user.login})"
      true
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Deleting '#{path}' failed: #{e.message}"
      false
    end

    def write_file(action)
      content = action.page.content
      content.write_to_md_file_with_frontmatter
      content.subwikifiles_write_error.nil?
    end

    def read_file(action)
      content = action.page.content
      RedmineSubwikifiles.without_auto_sync do
        content.text = action.file_body
        content.author = user
        content.comments = "Sync: #{File.basename(action.file_path)} → Wiki"
        content.save
      end
    end

    # Commit only the files that were taken over, so skipped conflicts keep their base
    def commit_paths(proj, paths)
      backend = GitBackend.new(proj)
      state = SyncState.new(proj)
      rels = paths.map { |p| state.relative(p) }
      backend.run_git('add', '--', *rels)
      author = "#{user.firstname} #{user.lastname} <#{user.mail.presence || 'redmine@example.com'}>"
      backend.run_git('commit', '-m', 'Sync: file -> wiki', '--author', author)
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: commit after sync failed: #{e.message}"
    end
  end
end

