require File.expand_path('../../../test_helper', __FILE__)

class RedmineSubwikifiles::FileStorageTest < ActiveSupport::TestCase
  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = { 'base_path' => @base_path }
    @project = Project.create!(
      name:       "FileStorageTest-#{SecureRandom.hex(4)}",
      identifier: "fs-test-#{SecureRandom.hex(4)}"
    )
    @storage      = RedmineSubwikifiles::FileStorage.new(@project)
    @project_path = @storage.project_path
  end

  def teardown
    @project.destroy if @project&.persisted?
    FileUtils.rm_rf(@base_path) if @base_path && File.exist?(@base_path)
  end

  def test_write_creates_file
    title   = "Test Page"
    content = "# Hello World"

    @storage.write(title, content)

    expected_path = File.join(@project_path, "Test_Page.md")
    assert File.exist?(expected_path)
    assert_equal content, File.read(expected_path)
  end

  def test_read_returns_content_and_mtime
    title   = "Existing Page"
    content = "Some content"
    path    = File.join(@project_path, "Existing_Page.md")

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)

    read_content, mtime = @storage.read(title)

    assert_equal content, read_content
    assert_not_nil mtime
  end

  def test_read_returns_nil_if_file_missing
    assert_nil @storage.read("Non Existent")
  end

  def test_file_path_sanitization
    # sanitize_filename: spaces → underscores, non-word/non-hyphen chars removed
    path = @storage.file_path("My Test Page")
    assert_match(/My_Test_Page\.md$/, path)
  end
end
