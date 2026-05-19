require File.expand_path('../../test_helper', __FILE__)

class FolderCreationTest < Redmine::IntegrationTest
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = { 'base_path' => @base_path, 'enabled' => 'true' }
    log_user('admin', 'admin')
  end

  def teardown
    FileUtils.remove_entry @base_path if File.exist?(@base_path)
  end

  def test_creating_subproject_creates_folder
    parent = projects(:ecookbook)
    parent_folder = File.join(@base_path, parent.name)
    FileUtils.mkdir_p(parent_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(parent_folder, parent)

    new_identifier = 'new-sub-test'
    new_name       = 'New Sub Test'

    assert_difference 'Project.count' do
      post '/projects', params: {
        project: {
          name:                  new_name,
          identifier:            new_identifier,
          parent_id:             parent.id,
          enabled_module_names:  ['redmine_subwikifiles']
        }
      }
    end

    sub = Project.find_by_identifier(new_identifier)
    assert sub, 'Subproject should have been created'

    # The hook creates the folder inside the parent folder
    sub_folder = RedmineSubwikifiles::FileStorage.new(sub).project_path
    assert Dir.exist?(sub_folder), "Subproject folder should have been created at #{sub_folder}"
  ensure
    Project.find_by_identifier(new_identifier)&.destroy
  end
end
