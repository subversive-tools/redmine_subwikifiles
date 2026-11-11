module RedmineSubwikifiles
  # Attaches a file from the project folder to a container (wiki page / wiki / project)
  # and moves it into the project's _attachments folder.
  # Shared by the "attach" fix button and the sync popover.
  class AttachmentImporter
    # @return [Hash] { success: true, container: obj } or { success: false, error: String }
    def self.attach(project, file_name, container = nil)
      storage = FileStorage.new(project)
      file_path = File.join(storage.project_path, file_name)
      return { success: false, error: "File not found on disk: #{file_name}" } unless File.exist?(file_path)

      container ||= project.wiki || project

      attachment = Attachment.new
      attachment.file = File.open(file_path)
      attachment.author = User.current
      attachment.container = container
      attachment.filename = file_name

      unless attachment.save
        return { success: false, error: attachment.errors.full_messages.join(', ') }
      end

      Rails.logger.info "RedmineSubwikifiles: Attached file '#{file_name}' to #{container.class.name} #{container.id}"

      # Move file to _attachments folder
      begin
        attachments_dir = File.join(storage.project_path, '_attachments')
        FileUtils.mkdir_p(attachments_dir)

        target_path = File.join(attachments_dir, file_name)
        if File.exist?(target_path)
          timestamp = Time.now.strftime('%Y%m%d%H%M%S')
          target_path = File.join(attachments_dir, "#{File.basename(file_name, '.*')}_#{timestamp}#{File.extname(file_name)}")
        end

        FileUtils.mv(file_path, target_path)
        Rails.logger.info "RedmineSubwikifiles: Moved '#{file_name}' to '#{target_path}'"
      rescue => e
        Rails.logger.error "RedmineSubwikifiles: Failed to move attached file: #{e.message}"
      end

      { success: true, container: container }
    end
  end
end

