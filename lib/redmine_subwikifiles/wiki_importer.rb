module RedmineSubwikifiles
  # Service class responsible for creating or updating Redmine WikiPages from filesystem data.
  class WikiImporter
    attr_reader :project
    
    def initialize(project)
      @project = project
    end

    # The header references a wiki page id that no longer exists: the page was deleted in Redmine.
    # Such files must not be re-imported automatically (deletion candidates, decided by the user).
    def self.deleted_page_reference?(metadata)
      id = (metadata || {})['id'] || (metadata || {})['wiki_id']
      id.present? && !WikiPage.exists?(id: id)
    end
    
    # Import a single file into Redmine as WikiPage
    # Returns: { success: bool, page_title: string, errors: [] }
    def import_file(file_info)
      return { success: false, errors: ["Invalid file info"] } unless file_info[:valid]
      
      title = Wiki.titleize(file_info[:filename])
      content = file_info[:content]
      metadata = file_info[:metadata] || {}
      
      # Try to find existing page by ID (robust rename handling)
      page = nil
      if metadata['id'] || metadata['wiki_id'] # Support both for transition or just 'id'
        page_id = metadata['id'] || metadata['wiki_id']
        page = project.wiki.pages.find_by(id: page_id)
        if page
          Rails.logger.info "RedmineSubwikifiles: Found existing page by ID #{page_id}: '#{page.title}' -> '#{title}'"
          if page.title != title
             # Rename detected!
             old_title = page.title
             # We must update the title.
             # The save below will handle the content update.
             page.title = title
             # Note: Redmine might redirect or handle renames specially, but setting title on instance works for save.
             renamed = true
          end
        end
      end
      
      # Create new WikiPage if not found
      page ||= project.wiki.pages.build(title: title)
      
      # Apply parent relationship if specified
      if metadata['parent']
        parent_page = project.wiki.find_page(metadata['parent'])
        if parent_page
          page.parent = parent_page
          Rails.logger.info "RedmineSubwikifiles: WikiImporter - Linked '#{title}' to parent '#{parent_page.title}' (ID: #{parent_page.id})"
        else
          # EXPERIMENTAL (to be clarified/tested, see doc/OPEN_ISSUES.md):
          # Parent exists neither as wiki page nor as file -> create a placeholder parent page
          # so the hierarchy from the files is preserved.
          parent_page = create_placeholder_parent(metadata['parent'], file_info[:filename])
          unless parent_page
            Rails.logger.warn "RedmineSubwikifiles: WikiImporter - Parent page '#{metadata['parent']}' NOT found and placeholder could not be created"
            return {
              success: false,
              page_title: title,
              errors: ["Parent page '#{metadata['parent']}' not found"]
            }
          end
          page.parent = parent_page
          placeholder_title = parent_page.title
        end
      end
      
      # Create WikiContent
      page.content = WikiContent.new(
        text: content,
        author: User.current,
        comments: "Imported from filesystem"
      )
      
      # Override timestamps if provided in frontmatter
      if metadata['created']
        begin
          page.created_on = Time.parse(metadata['created'])
        rescue ArgumentError
          # Ignore invalid date
        end
      end
      
      # Save page (this will trigger our write_to_md_file callback, but with sync flag)
      begin
        if page.save
          # If this was an import from an orphan file, we might need to delete the original
          # to avoid a loop (e.g. if title normalization changed the name)
          storage = RedmineSubwikifiles::FileStorage.new(project)
          new_path = storage.file_path(page.title)
          original_path = file_info[:path]
          
          if original_path && File.exist?(original_path) && original_path != new_path
             File.delete(original_path)
             Rails.logger.info "RedmineSubwikifiles: Deleted original orphan file #{original_path} after importing as #{new_path}"
          end
          
          Rails.logger.info "RedmineSubwikifiles: Imported '#{title}' from filesystem"
          result = { success: true, page_title: title }
          result[:placeholder] = placeholder_title if placeholder_title
          if renamed
            result[:renamed] = true
            result[:old_title] = old_title
          end
          result
        else
          { success: false, page_title: title, errors: page.errors.full_messages }
        end
      end
    rescue => e
      Rails.logger.error "RedmineSubwikifiles: Import error for '#{title}': #{e.message}"
      { success: false, page_title: title, errors: [e.message] }
    end
    
    # Import multiple files
    # Returns: { imported: [], renamed: [], skipped: [], placeholders: [] }
    def import_files(file_infos)
      imported = []
      renamed = []
      skipped = []
      placeholders = []
      
      file_infos.each do |file_info|
        result = import_file(file_info)
        
        if result[:success]
          placeholders << result[:placeholder] if result[:placeholder]
          if result[:renamed]
            renamed << { old_title: result[:old_title], new_title: result[:page_title] }
          else
            imported << result[:page_title]
          end
        else
          skipped << { 
            file: file_info[:filename], 
            errors: result[:errors] || ["Unknown error"]
          }
        end
      end
      
      { imported: imported, renamed: renamed, skipped: skipped, placeholders: placeholders.uniq }
    end

    private

    # EXPERIMENTAL: creates an empty parent page listing its children.
    # Saving it also writes the corresponding Markdown file (WikiContentPatch).
    # Returns the page or nil.
    def create_placeholder_parent(parent_title, child_filename)
      title = Wiki.titleize(parent_title.to_s)
      return nil if title.blank?

      existing = project.wiki.find_page(title)
      return existing if existing

      placeholder = project.wiki.pages.build(title: title)
      placeholder.content = WikiContent.new(
        text: "{{child_pages}}\n",
        author: User.current,
        comments: "Placeholder created: referenced as parent by '#{child_filename}.md'"
      )
      if placeholder.save
        Rails.logger.info "RedmineSubwikifiles: WikiImporter - Created placeholder parent page '#{title}' for '#{child_filename}'"
        placeholder
      else
        Rails.logger.error "RedmineSubwikifiles: WikiImporter - Placeholder '#{title}' failed: #{placeholder.errors.full_messages.join(', ')}"
        nil
      end
    end
  end
end
