require File.expand_path('../../test_helper', __FILE__)

class FolderCreationTest < Redmine::IntegrationTest
  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = { 'base_path' => @base_path, 'enabled' => 'true' }

    # Create a fresh admin user with a known password for log_user
    @admin = User.find_by(login: 'admin') || User.new(
      login:     'admin',
      firstname: 'Admin',
      lastname:  'Test',
      mail:      'admin@example.com',
      admin:     true,
      status:    User::STATUS_ACTIVE
    )
    unless @admin.persisted?
      @admin.password = 'admin'
      @admin.password_confirmation = 'admin'
      @admin.save!
    end

    # Create parent project from scratch (no fixture dependency)
    @parent = Project.create!(
      name:       "ParentProject-#{SecureRandom.hex(4)}",
      identifier: "parent-proj-#{SecureRandom.hex(4)}"
    )

    parent_folder = File.join(@base_path, @parent.name)
    FileUtils.mkdir_p(parent_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(parent_folder, @parent)

    log_user('admin', 'admin')
  end

  def teardown
    @parent.destroy if @parent&.persisted?
    FileUtils.remove_entry @base_path if File.exist?(@base_path)
  end

  def test_creating_subproject_creates_folder
    new_identifier = "new-sub-#{SecureRandom.hex(4)}"
    new_name       = "NewSub-#{SecureRandom.hex(4)}"

    assert_difference 'Project.count' do
      post '/projects', params: {
        project: {
          name:                 new_name,
          identifier:           new_identifier,
          parent_id:            @parent.id,
          enabled_module_names: ['redmine_subwikifiles']
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
