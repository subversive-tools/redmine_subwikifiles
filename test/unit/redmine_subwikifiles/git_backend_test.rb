require File.expand_path('../../../test_helper', __FILE__)
require 'mocha/minitest'

class RedmineSubwikifiles::GitBackendTest < ActiveSupport::TestCase
  fixtures :projects, :users

  def setup
    @base_path = Dir.mktmpdir
    Setting.plugin_redmine_subwikifiles = { 'base_path' => @base_path }
    @project = projects(:ecookbook)
    @user    = users(:admin)

    # Pre-create the .git marker so GitBackend#initialize skips init_repo
    project_path = RedmineSubwikifiles::FileStorage.new(@project).project_path
    FileUtils.mkdir_p(File.join(project_path, '.git'))

    @backend = RedmineSubwikifiles::GitBackend.new(@project)
  end

  def teardown
    FileUtils.rm_rf(@base_path) if @base_path && File.exist?(@base_path)
  end

  def test_commit_executes_git_add_and_commit
    @backend.expects(:run_git).with('add', 'Test_Page.md').returns("")
    @backend.expects(:run_git).with(
      'commit', '-m', 'Update Test Page',
      '--author', "#{@user.firstname} #{@user.lastname} <#{@user.mail}>",
      '--allow-empty-message'
    ).returns("")

    @backend.commit('Test Page', author: @user, message: 'Update Test Page')
  end
end
