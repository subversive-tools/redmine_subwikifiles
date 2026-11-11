module RedmineSubwikifiles
  # Sync status chip + popover on wiki pages (and the wiki index).
  # JS/CSS are inlined so it works the same on Redmine 4-7 regardless of the asset pipeline.
  class SyncUiHooks < Redmine::Hook::ViewListener
    ASSET_DIR = File.expand_path('../../../app/assets', __FILE__)

    STATUS_CLASS = {
      ok: '', create_file: 'swf-info', to_wiki: 'swf-info', to_file: 'swf-info',
      conflict: 'swf-warn', deleted: 'swf-warn', error: 'swf-error', index: '', new_files: 'swf-info'
    }.freeze

    def view_layouts_base_html_head(context = {})
      controller = context[:controller]
      return '' unless controller && controller.class.name == 'WikiController'
      return '' unless %w[show index edit].include?(controller.action_name)

      project = controller.instance_variable_get(:@project)
      return '' unless project && project.wiki
      return '' unless User.current.allowed_to?(:edit_wiki_pages, project)
      return '' unless ProjectSync.enabled_for?(project)

      view = context[:hook_caller]
      if controller.action_name == 'edit'
        return '' unless RedmineSubwikifiles.live_preview_enabled?

        live_cfg = {
          token: controller.send(:form_authenticity_token),
          label: I18n.t('redmine_subwikifiles.live_preview.tab'),
          tip: I18n.t('redmine_subwikifiles.live_preview.tip'),
          dividerTip: I18n.t('redmine_subwikifiles.live_preview.divider_tip')
        }
        return view.content_tag(:style, self.class.asset('stylesheets/subwikifiles_live_preview.css').html_safe) +
          view.javascript_tag("window.SWF_LIVE_PREVIEW = #{live_cfg.to_json};\n#{self.class.asset('javascripts/subwikifiles_live_preview.js')}")
      end

      page = controller.action_name == 'show' ? controller.instance_variable_get(:@page) : nil
      page = nil unless page && page.persisted?
      # Only on the current version of a page
      return '' if page && controller.params[:version].present?

      status = page_status(project, page)
      new_files = 0
      if %i[ok index].include?(status)
        new_files = FileScanner.new(project).scan_for_new_files[:orphaned].size
        status = :new_files if new_files > 0
      end
      view = context[:hook_caller]

      label = status == :new_files ? I18n.t('redmine_subwikifiles.sync_ui.status_new_files', count: new_files) : I18n.t("redmine_subwikifiles.sync_ui.status_#{status}")
      tip = I18n.t("redmine_subwikifiles.sync_ui.status_tip_#{status}")
      chip_html = chip(view, label, tip, STATUS_CLASS[status].to_s)

      config = {
        planUrl: view.url_for(controller: '/subwikifiles', action: 'plan', project_id: project.identifier, only_path: true),
        autoUrl: view.url_for(controller: '/subwikifiles', action: 'auto', project_id: project.identifier, only_path: true),
        applyUrl: view.url_for(controller: '/subwikifiles', action: 'apply', project_id: project.identifier, only_path: true),
        page: page&.title,
        token: controller.send(:form_authenticity_token),
        chip: chip_html,
        status: { cls: STATUS_CLASS[status].to_s },
        t: I18n.t('redmine_subwikifiles.sync_ui')
      }

      view.content_tag(:style, self.class.asset('stylesheets/subwikifiles_sync.css').html_safe) +
        view.javascript_tag("window.SWF_SYNC = #{config.to_json};\n#{self.class.asset('javascripts/subwikifiles_sync.js')}")
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: sync UI failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      ''
    end

    def self.asset(rel)
      @assets ||= {}
      @assets[rel] = nil if Rails.env.development?
      @assets[rel] ||= File.read(File.join(ASSET_DIR, rel), encoding: 'UTF-8')
    end

    private

    # Rendered like the other links in the contextual bar ("Bearbeiten", "Beobachten"):
    # Redmine 6+ uses SVG sprite icons, Redmine 4/5 the icon-* background images.
    # The state is shown by a small colored dot after the label.
    def chip(view, label, tip, state_class)
      inner =
        if view.respond_to?(:sprite_icon)
          view.sprite_icon('reload', label)
        else
          ERB::Util.html_escape(label)
        end
      inner += view.content_tag(:span, '', class: 'swf-dot') if state_class.present?
      view.link_to(inner, '#', class: "icon icon-reload swf-chip #{state_class}".strip, title: tip)
    end

    def page_status(project, page)
      storage = FileStorage.new(project)
      return :error unless writable_location?(storage.project_path)
      return :index unless page

      SyncState.new(project, storage: storage).classify(page).state
    end

    # The project folder (or its nearest existing parent) must be writable
    def writable_location?(path)
      p = path
      p = File.dirname(p) until File.exist?(p) || p == File.dirname(p)
      File.directory?(p) && File.writable?(p)
    end
  end
end
