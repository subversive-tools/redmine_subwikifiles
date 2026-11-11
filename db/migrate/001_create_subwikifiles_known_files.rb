# Remembers which wiki page already had a file and where it was located.
# Used to tell "file was deleted" from "file never existed" even if the whole folder
# (including its Git repository) was deleted.
class CreateSubwikifilesKnownFiles < ActiveRecord::Migration[5.2]
  def change
    create_table :subwikifiles_known_files do |t|
      t.integer :page_id, null: false
      t.integer :project_id, null: false
      t.string :path, limit: 1024, null: false
      t.datetime :synced_at
    end
    add_index :subwikifiles_known_files, :page_id, unique: true
    add_index :subwikifiles_known_files, :project_id
  end
end
