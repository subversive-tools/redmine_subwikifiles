require File.expand_path('../../test_helper', __FILE__)

class ProjectSyncTest < Redmine::IntegrationTest
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @base_path = Dir.mktmpdir
    # db_wins: Redmine name changes trigger actual folder renames
    Setting.plugin_redmine_subwikifiles = {
      'base_path'         => @base_path,
      'enabled'           => 'true',
      'conflict_strategy' => 'db_wins'
    }
    @project = projects(:ecookbook)
    # Insert via SQL to bypass any EnabledModule name-validation timing issues
    unless @project.module_enabled?('redmine_subwikifiles')
      ActiveRecord::Base.connection.execute(
        "INSERT INTO enabled_modules (project_id, name) VALUES (#{@project.id}, 'redmine_subwikifiles')"
      )
    end
    @project.reload
  end

  def teardown
    FileUtils.remove_entry @base_path if File.exist?(@base_path)
  end

  def test_renaming_project_name_renames_folder
    # Create the initial folder with .project metadata
    storage         = RedmineSubwikifiles::FileStorage.new(@project)
    original_folder = storage.project_path
    FileUtils.mkdir_p(original_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(original_folder, @project)

    assert Dir.exist?(original_folder), "Original folder should exist before rename"

    new_name = 'Renamed Wiki Project'
    @project.name = new_name
    @project.save!

    # The hook renames the folder to the raw new name (no sanitization)
    expected_path = File.join(@base_path, new_name)
    assert Dir.exist?(expected_path),
           "Folder should be renamed to '#{expected_path}' after project name change"
    refute Dir.exist?(original_folder),
           "Original folder '#{original_folder}' should be gone after rename"
  end

  def test_renaming_project_identifier_updates_metadata
    # Create folder and write metadata with original identifier
    storage         = RedmineSubwikifiles::FileStorage.new(@project)
    original_folder = storage.project_path
    FileUtils.mkdir_p(original_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(original_folder, @project)

    original_identifier = @project.identifier
    new_identifier      = 'renamed-identifier-test'

    @project.identifier = new_identifier
    @project.save!

    # The folder keeps its name (named after project name, not identifier)
    # but .project metadata is updated with the new identifier
    assert Dir.exist?(original_folder),
           "Folder should still exist after identifier-only rename"
    metadata = File.read(File.join(original_folder, '.project'))
    assert_includes metadata, "id: #{new_identifier}",
                    ".project metadata should reflect the new identifier"
  ensure
    @project.update_column(:identifier, original_identifier) if original_identifier
  end
end
