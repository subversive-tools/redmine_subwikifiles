require 'open3'

module RedmineSubwikifiles
  # Determines the sync state of wiki pages using a three-way comparison:
  # wiki text, file body and the *base* = last committed version of the file in the project's
  # Git repository (every sync/save is committed, so HEAD is the last common state).
  #
  # States:
  #   :ok           wiki and file are identical
  #   :create_file  file never existed (not in Git history)       -> write file from wiki
  #   :deleted      file existed (Git history) but is gone       -> decision: restore / skip
  #   :to_wiki      only the file changed since base             -> file -> wiki
  #   :to_file      only the wiki changed since base             -> wiki -> file
  #   :conflict     both changed since base                      -> decision: file / wiki / skip
  #   :unknown_base no base available; resolved by "newer wins" (reported as :to_wiki / :to_file
  #                 with fallback: true)
  #
  # Read-only: never writes files, never initializes repositories.
  class SyncState
    Result = Struct.new(:state, :fallback, :file_path, :file_body, :keyword_init => true)

    attr_reader :project, :storage

    def initialize(project, storage: nil)
      @project = project
      @storage = storage || FileStorage.new(project)
      @tracked = nil
    end

    def self.normalize(text)
      text.to_s.gsub("\r\n", "\n").strip
    end

    # Body (without frontmatter) of a Markdown text
    def self.body(text)
      FrontmatterParser.parse(text.to_s)[:content].to_s
    end

    # @param page [WikiPage]
    # @param content [WikiContent] (optional, avoids reloading)
    def classify(page, content = nil)
      content ||= RedmineSubwikifiles.without_auto_sync { page.content }
      return Result.new(state: :ok) unless content

      path = storage.resolve_existing_path(page.title)

      unless path
        rel = relative(storage.file_path(page.title))
        # Deleted if the page is known to have had a file in this folder (registry, survives
        # deleting the whole folder incl. .git) or if Git history knows the file.
        existed = KnownFile.had_file_in?(page, storage.project_path) || ever_tracked?(rel)
        return Result.new(state: existed ? :deleted : :create_file, file_path: storage.file_path(page.title))
      end

      KnownFile.remember(page, path)

      raw = File.read(path, encoding: 'UTF-8')
      file_body = self.class.body(raw)
      wiki = self.class.normalize(content.text)
      file = self.class.normalize(file_body)
      return Result.new(state: :ok, file_path: path, file_body: file_body) if wiki == file

      base_raw = base_content(relative(path))
      if base_raw.nil?
        newer = File.mtime(path) > content.updated_on ? :to_wiki : :to_file
        return Result.new(state: newer, fallback: true, file_path: path, file_body: file_body)
      end

      base = self.class.normalize(self.class.body(base_raw))
      state =
        if file == base then :to_file      # only wiki changed
        elsif wiki == base then :to_wiki   # only file changed
        else :conflict
        end
      Result.new(state: state, file_path: path, file_body: file_body)
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: SyncState failed for '#{page&.title}': #{e.message}"
      Result.new(state: :ok)
    end

    # Default choice for a conflict according to the configured strategy
    def self.conflict_default(file_path, content)
      case RedmineSubwikifiles.conflict_strategy
      when 'db_wins' then 'wiki'
      when 'manual'
        file_path && File.exist?(file_path) && File.mtime(file_path) > content.updated_on ? 'file' : 'wiki'
      else 'file'
      end
    end

    # Content of a file in HEAD of the project repository, nil if unavailable
    def base_content(rel)
      return nil unless repo?
      out, _err, status = Open3.capture3('git', '-C', repo_path, 'show', "HEAD:#{rel}")
      status.success? ? out.force_encoding('UTF-8') : nil
    end

    def ever_tracked?(rel)
      return false unless repo?
      out, _err, status = Open3.capture3('git', '-C', repo_path, 'log', '-1', '--format=%H', '--', rel)
      status.success? && out.strip.present?
    end

    def repo?
      File.exist?(File.join(repo_path, '.git'))
    end

    def repo_path
      storage.project_path
    end

    def relative(path)
      path.to_s.sub(/\A#{Regexp.escape(repo_path)}\/?/, '')
    end
  end
end

