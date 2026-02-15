module RedmineSubwikifiles
  # Handles various Redmine hooks for the subwikifiles plugin.
  class Hooks < Redmine::Hook::ViewListener
    
    # Hide the module checkbox in project settings if plugin is globally enabled
    def view_projects_form(context={})
      return '' unless context[:project]
      
      if Setting.plugin_redmine_subwikifiles['enabled']
        return <<-HTML.html_safe
          <style>
            /* Hide the redmine_subwikifiles module checkbox when globally enabled */
            label:has(input[name="project[enabled_module_names][]"][value="redmine_subwikifiles"]) {
              display: none;
            }
          </style>
        HTML
      end
      
      ''
    end
    
    # Hook triggered after a project is saved.
    # Creates folder structure for new subprojects.
    def controller_projects_new_after_save(context={})
      project = context[:project]
      return unless project && project.parent
      return unless project.parent.module_enabled?(:redmine_subwikifiles)
      
      require File.expand_path('../file_storage', __FILE__)
      storage = RedmineSubwikifiles::FileStorage.new(project)
      project_path = storage.project_path
      
      unless Dir.exist?(project_path)
        FileUtils.mkdir_p(project_path)
        Rails.logger.info "RedmineSubwikifiles: Created subproject folder #{project_path}"
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Failed to create subproject folder: #{e.message}"
    end
  end
end
