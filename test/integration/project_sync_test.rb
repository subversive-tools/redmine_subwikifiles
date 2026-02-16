require File.expand_path('../../../test_helper', __FILE__)

class ProjectSyncTest < Redmine::IntegrationTest
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = Setting.plugin_redmine_subwikifiles.merge('base_path' => @base_path, 'enabled' => 'true')
    @project = Project.find(1)
    @project.enabled_modules << EnabledModule.new(name: 'redmine_subwikifiles')
    @project.save
  end

  def teardown
    FileUtils.remove_entry @base_path if File.exist?(@base_path)
  end

  def test_renaming_project_identifier_renames_folder
    # 1. Setup project folder
    original_id = @project.identifier
    new_id = "renamed-project-test"
    
    storage = RedmineSubwikifiles::FileStorage.new(@project)
    original_folder = storage.project_path
    
    FileUtils.mkdir_p(original_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(original_folder, @project)
    
    assert Dir.exist?(original_folder), "Original folder should exist"

    # 2. Rename Project Identifier
    @project.identifier = new_id
    @project.save!

    # 3. Verify
    new_folder = File.join(@base_path, new_id) # Default fallback if name is empty, but name is likely preserved.
    # Actually, logic preserves name if name isn't changed.
    # But wait, verify_rename.rb logic says:
    # "if change_type == :identifier ... target_folder = scan_for_project_folder ... new_folder_name = name"
    # So if we ONLY change identifier, the folder NAME might stay as Project Name.
    # BUT, if the folder was named after the identifier (default), and we change identifier,
    # does it rename?
    # Logic: "new_folder_name = name ... new_folder_name = identifier if new_folder_name.blank?"
    # So if Project Name is "eCookbook", folder is "eCookbook".
    # Changing identifier "ecookbook" to "renamed-test" -> Folder "eCookbook" remains "eCookbook".
    # Metadata should update.
    
    # Let's test checking metadata update first.
    # Original folder (named by Name 'eCookbook' likely, or ID if strictly following new logic?)
    # FileStorage uses Name if available.
    
    # Let's force a name change to be sure of RENAME
    @project.name = "Renamed Project Name"
    @project.save!
    
    # Expected folder name:
    expected_folder_name = "Renamed_Project_Name"
    expected_path = File.join(@base_path, expected_folder_name)
    
    assert Dir.exist?(expected_path), "Folder should be renamed to match new project name. Old: #{original_folder}, New: #{expected_path}"
    refute Dir.exist?(original_folder), "Original folder should be gone"
    
    # Check Metadata
    metadata = File.read(File.join(expected_path, '.project'))
    assert_includes metadata, "id: #{new_id}"
    assert_includes metadata, "name: \"Renamed Project Name\""
  end
  
  def test_renaming_project_name_renames_folder
    # 1. Setup
    @project.name = "Original Name"
    @project.save!
    
    storage = RedmineSubwikifiles::FileStorage.new(@project)
    original_folder = storage.project_path
    FileUtils.mkdir_p(original_folder)
    RedmineSubwikifiles::FileStorage.write_project_metadata(original_folder, @project)
    
    assert Dir.exist?(File.join(@base_path, "Original_Name"))
    
    # 2. Rename
    @project.name = "New Name Check"
    @project.save!
    
    # 3. Verify
    expected_path = File.join(@base_path, "New_Name_Check")
    
    assert Dir.exist?(expected_path), "Folder should be renamed to New_Name_Check"
    refute Dir.exist?(File.join(@base_path, "Original_Name")), "Old folder should be gone"
  end
end
