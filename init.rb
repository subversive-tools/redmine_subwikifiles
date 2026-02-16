# Register the Redmine Subwikifiles plugin
Redmine::Plugin.register :redmine_subwikifiles do
  name 'Redmine Subwikifiles'
  author 'Stefan Mischke'
  description 'Bidirectional synchronization of Redmine Wiki pages and local Markdown files with integrated Git support.'
  version '0.4.0'
  url 'https://github.com/modoq/redmine_subwikifiles'
  author_url 'https://github.com/modoq'

  # Default plugin settings
  settings default: {
    'base_path' => '/var/lib/redmine/wiki_files',
    'enabled' => false,
    'conflict_strategy' => 'file_wins'
  }, partial: 'settings/redmine_subwikifiles_settings'
  
  # Permission module for project-level settings and management
  project_module :redmine_subwikifiles do
    permission :manage_subwikifiles, { 
      subwikifiles: [:settings, :folder_prompt, :assign_folder, :fix_frontmatter, :attach_file] 
    }, require: :member
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
  require File.expand_path('../lib/redmine_subwikifiles/frontmatter_fixer', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/file_scanner', __FILE__)
  require File.expand_path('../lib/redmine_subwikifiles/wiki_importer', __FILE__)
  
  # 2. Setup View Hooks (for UI element injection)
  require File.expand_path('../lib/redmine_subwikifiles/view_hooks', __FILE__)
  
  # 3. Apply Model Patches
  # Patch WikiContent: Handle file write-back on wiki save
  require File.expand_path('../lib/redmine_subwikifiles/wiki_content_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching WikiContent"
  WikiContent.send(:include, RedmineSubwikifiles::WikiContentPatch)
  
  # Patch WikiPage: Handle file renames and deletions
  require File.expand_path('../lib/redmine_subwikifiles/wiki_page_patch', __FILE__)
  Rails.logger.info "RedmineSubwikifiles: Patching WikiPage"
  WikiPage.send(:include, RedmineSubwikifiles::WikiPagePatch)
  
  # 4. Apply Controller Patches
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
