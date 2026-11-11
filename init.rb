# Register the Redmine Subwikifiles plugin
Redmine::Plugin.register :redmine_subwikifiles do
  name 'Subwikifiles'
  author 'Stefan Mischke'
  description 'Bidirectional synchronization of Redmine Wiki pages and local Markdown files with integrated Git support.'
  version '0.5.2'
  url 'https://github.com/subversive-tools/redmine_subwikifiles'
  author_url 'https://github.com/modoq'

  # Default plugin settings
  settings default: {
    'base_path' => '/var/lib/redmine/wiki_files',
    'enabled' => false,
    'conflict_strategy' => 'file_wins',
    'live_preview' => '1'
  }, partial: 'settings/redmine_subwikifiles_settings'
  
  # Permission module for project-level settings and management
  project_module :redmine_subwikifiles do
    permission :manage_subwikifiles, { 
      subwikifiles: [:settings, :folder_prompt, :assign_folder, :fix_frontmatter, :attach_file] 
    }, require: :member
  end
end

module RedmineSubwikifiles
  DEFAULT_BASE_PATH = '/var/lib/redmine/wiki_files'.freeze

  # Minimum interval between two automatic background syncs of the same project tree
  AUTO_INTERVAL = 60.seconds

  @throttle = {}
  @throttle_mutex = Mutex.new

  # Returns true (and reserves the slot) if the key was not used within `interval`.
  # Uses the Rails cache when it is a real store (shared between processes), otherwise an
  # in-process memory map (e.g. NullStore in development).
  def self.throttle_slot?(key, interval = AUTO_INTERVAL)
    unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
      return Rails.cache.write("redmine_subwikifiles/#{key}", Time.now.to_i, expires_in: interval, unless_exist: true)
    end
    @throttle_mutex.synchronize do
      now = Time.now.to_f
      return false if @throttle[key] && now - @throttle[key] < interval.to_f
      @throttle[key] = now
      true
    end
  end

  # Configured base path, with surrounding whitespace removed
  # (pasted paths often contain trailing spaces).
  def self.base_path
    Setting.plugin_redmine_subwikifiles['base_path'].to_s.strip.presence || DEFAULT_BASE_PATH
  end

  # Configured conflict strategy: 'file_wins' (default), 'db_wins' or 'manual' (bidirectional)
  def self.conflict_strategy
    s = Setting.plugin_redmine_subwikifiles['conflict_strategy'].to_s
    %w[file_wins db_wins manual].include?(s) ? s : 'file_wins'
  end

  # Whether the plugin is enabled globally or for the given project (or any of its ancestors)
  def self.enabled_for?(project)
    return false unless project
    return true if ActiveModel::Type::Boolean.new.cast(Setting.plugin_redmine_subwikifiles['enabled'])

    project.self_and_ancestors.any? { |p| p.module_enabled?(:redmine_subwikifiles) }
  end

  # Whether the HedgeDoc-style live split preview in the wiki editor is enabled (default: true)
  def self.live_preview_enabled?
    val = Setting.plugin_redmine_subwikifiles['live_preview']
    val.nil? ? true : ActiveModel::Type::Boolean.new.cast(val)
  end

  # Temporarily suppresses automatic model/controller sync callbacks in the current thread
  def self.without_auto_sync
    previous = Thread.current[:redmine_subwikifiles_syncing]
    Thread.current[:redmine_subwikifiles_syncing] = true
    yield
  ensure
    Thread.current[:redmine_subwikifiles_syncing] = previous
  end
end

# Application Setup: Apply patches and load dependencies
Rails.logger.info "RedmineSubwikifiles: Loading plugin..."

# Directly applying patches. 
# Note: In development mode, some Redmine versions might require configuration.to_prepare blocks.
begin
  # 1. Load Core Services
  require File.expand_path('../lib/redmine_subwikifiles/frontmatter_parser', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/file_storage', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/file_lock_checker', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/file_scanner', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/wiki_importer', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/project_sync', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/known_file', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/attachment_importer', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/sync_state', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/sync_plan', __FILE__)
  
  # 2. Setup Hooks (controller hooks: subproject folder creation, etc.)
  require File.expand_path('../lib/redmine_subwikifiles/hooks', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/sync_ui_hooks', __FILE__)

  # 3. Setup View Hooks (for UI element injection)
  require File.expand_path('../lib/redmine_subwikifiles/view_hooks', __FILE__)
  
  # 4. Apply Model Patches
  # Patch WikiContent: Handle file write-back on wiki save
  require File.expand_path('../lib/redmine_subwikifiles/wiki_content_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching WikiContent"
  WikiContent.send(:include, RedmineSubwikifiles::WikiContentPatch)
  
  # Patch WikiPage: Handle file renames and deletions
  require File.expand_path('../lib/redmine_subwikifiles/wiki_page_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching WikiPage"
  WikiPage.send(:include, RedmineSubwikifiles::WikiPagePatch)
  
  # 5. Apply Controller Patches
  # Patch WikiController: Handle file synchronization on page load
  require File.expand_path('../lib/redmine_subwikifiles/wiki_controller_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching WikiController"
  WikiController.send(:include, RedmineSubwikifiles::WikiControllerPatch)
  
  # Patch Project: Handle folder renaming on identifier change
  require File.expand_path('../lib/redmine_subwikifiles/project_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching Project"
  Project.send(:include, RedmineSubwikifiles::ProjectPatch)
  
  Rails.logger.info "RedmineSubwikifiles: Plugin initialization and patching completed successfully"
rescue => e
  Rails.logger.error "RedmineSubwikifiles: Failed to initialize plugin or apply patches: #{e.message}"
  Rails.logger.error e.backtrace.join("\n")
end
