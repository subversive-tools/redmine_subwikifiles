module RedmineSubwikifiles
  # Registry of pages that already had a file (see db/migrate/001_create_subwikifiles_known_files.rb).
  class KnownFile < ActiveRecord::Base
    self.table_name = 'subwikifiles_known_files'

    def self.available?
      return @available if defined?(@available) && @available
      @available = table_exists?
    rescue => e
      Rails.logger.warn "RedmineSubwikifiles: known files registry unavailable: #{e.message}"
      false
    end

    # Records that the page has a file at path (only writes if new or moved)
    def self.remember(page, path)
      return unless available? && page&.id && path
      rec = find_or_initialize_by(page_id: page.id)
      return if rec.persisted? && rec.path == path.to_s
      rec.project_id = page.wiki&.project_id
      rec.path = path.to_s
      rec.synced_at = Time.now
      rec.save
    rescue => e
      Rails.logger.warn "RedmineSubwikifiles: could not remember file for page #{page&.id}: #{e.message}"
    end

    def self.forget(page)
      return unless available? && page&.id
      where(page_id: page.id).delete_all
    rescue => e
      Rails.logger.warn "RedmineSubwikifiles: could not forget page #{page&.id}: #{e.message}"
    end

    # True if the page had a file in the given project folder (i.e. it was deleted there).
    # A different folder (e.g. changed base path) does not count.
    def self.had_file_in?(page, project_path)
      return false unless available? && page&.id
      rec = find_by(page_id: page.id)
      return false unless rec
      File.dirname(rec.path) == project_path.to_s.chomp('/')
    rescue
      false
    end
  end
end
