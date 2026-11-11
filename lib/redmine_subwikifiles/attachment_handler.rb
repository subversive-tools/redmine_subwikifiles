module RedmineSubwikifiles
  # Handles synchronization of wiki page attachments between Redmine and the filesystem.
  # Attachments are stored in a '_attachments' subdirectory within the project folder.
  class AttachmentHandler
    def initialize(page)
      @page = page
      @project = page.project
      @project_path = FileStorage.new(@project).project_path
      
      # Determine attachment folder based on page title
      sanitized_title = get_sanitized_title
      @attachment_dir = File.join(@project_path, '_attachments', sanitized_title)
    end

    # Synchronizes attachments from Redmine to the filesystem.
    def sync_to_fs
      return unless @page.attachments.any?
      
      FileUtils.mkdir_p(@attachment_dir)
      
      @page.attachments.each do |attachment|
        target_path = File.join(@attachment_dir, attachment.filename)
        
        # Only copy if source exists and target doesn't or is different
        source_path = attachment.diskfile
        if File.exist?(source_path)
          FileUtils.cp(source_path, target_path)
        end
      end
    end

    def sync_from_fs
      return unless File.directory?(@attachment_dir)
      
      Dir.glob(File.join(@attachment_dir, '*')).each do |file_path|
        next unless File.file?(file_path)
        filename = File.basename(file_path)
        
        # Check if attachment already exists
        unless @page.attachments.exists?(filename: filename)
          File.open(file_path) do |file|
            a = Attachment.new(file: file)
            a.filename = filename
            a.author = User.current
            a.container = @page
            a.save
          end
        end
      end
    end

    private

    def get_sanitized_title
      if @page.respond_to?(:ancestors) && @page.ancestors.any?
        (@page.ancestors.map(&:title) + [@page.title]).join('/').gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      else
        @page.title.gsub(' ', '_').gsub(/[^\w\/\-]/, '')
      end
    end
  end
end
