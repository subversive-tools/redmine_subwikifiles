require File.expand_path('../../test_helper', __FILE__)

# Tests that the controller_projects_new_after_save hook creates the subproject
# folder when a subproject is created.  We exercise the hook directly rather
# than via a real HTTP POST so that the Setting written in setup is always
# visible to the hook (avoids DB-connection isolation issues in integration
# tests with transactional fixtures).
class FolderCreationTest < ActiveSupport::TestCase
  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = { 'base_path' => @base_path, 'enabled' => 'true' }
    Setting.clear_cache

    # Create a parent project and its on-disk folder with .project metadata
    @parent = Project.create!(
      name:       "ParentProject-#{SecureRandom.hex(4)}",
      identifier: "parent-proj-#{SecureRandom.hex(4)}"
    )

    parent_folder = File.join(@base_path, @parent.name)
    FileUtils.mkdir_p(parent_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(parent_folder, @parent)

    # Enable the module on the parent so module_enabled? check in the hook passes
    ActiveRecord::Base.connection.execute(
      "INSERT INTO enabled_modules (project_id, name) VALUES (#{@parent.id}, 'redmine_subwikifiles')"
    )
    @parent.reload
  end

  def teardown
    @parent.destroy if @parent&.persisted?
    FileUtils.remove_entry @base_path if File.exist?(@base_path)
  end

  def test_creating_subproject_creates_folder
    new_identifier = "new-sub-#{SecureRandom.hex(4)}"
    new_name       = "NewSub-#{SecureRandom.hex(4)}"

    sub = Project.create!(
      name:       new_name,
      identifier: new_identifier,
      parent_id:  @parent.id
    )
    ActiveRecord::Base.connection.execute(
      "INSERT INTO enabled_modules (project_id, name) VALUES (#{sub.id}, 'redmine_subwikifiles')"
    )
    sub.reload

    # Invoke the hook the same way ProjectsController#create does after save
    Redmine::Hook.call_hook(:controller_projects_new_after_save, project: sub)

    sub_folder = RedmineSubwikifiles::FileStorage.new(sub).project_path
    assert Dir.exist?(sub_folder), "Subproject folder should have been created at #{sub_folder}"
  ensure
    Project.find_by_identifier(new_identifier)&.destroy
  end
end
