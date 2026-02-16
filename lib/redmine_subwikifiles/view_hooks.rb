module RedmineSubwikifiles
  # Responsible for injecting JavaScript and CSS into Redmine views (layouts/base).
  # Handles the interactive "Fix" buttons for orphan files and displays file paths in the editor.
  class ViewHooks < Redmine::Hook::ViewListener
    Rails.logger.info "RedmineSubwikifiles: ViewHooks file loaded"
    
    def initialize
      super
      Rails.logger.info "RedmineSubwikifiles: ViewHooks initialized"
    end
    
    # Inject JS to handle "fix file" buttons and show file path in edit mode
    def view_layouts_base_html_head(context = {})
      Rails.logger.info "RedmineSubwikifiles: view_layouts_base_html_head called"
      
      controller = context[:controller]
      return '' unless controller
      
      # 1. Existing JS for 'fix file' buttons (orphans)
      js = build_js(controller)
      response = javascript_tag(js)
      
      # 2. JS for folder buttons
      folder_js = build_folder_js(controller)
      response += javascript_tag(folder_js) if folder_js.present?
      
      # 3. Inject file path info if in Wiki Edit mode
      if controller.is_a?(WikiController) && controller.action_name == 'edit'
        file_path = controller.instance_variable_get(:@associated_file_path)
        if file_path
           # Calculate relative path from base
           base_dir = Setting.plugin_redmine_subwikifiles['base_path'] || '/var/lib/redmine/wiki_files'
           relative_path = file_path.sub(base_dir, '')
           
           # Ensure it starts with /
           relative_path = "/#{relative_path}" unless relative_path.start_with?('/')
           
           safe_path = CGI.escapeHTML(relative_path)
           
           # Use simple <p> tag to match other form fields
           info_html = <<~HTML.strip.gsub("\n", "")
             <p id="subwikifiles_path_info">
               #{safe_path}
             </p>
           HTML
           
           path_js = <<~JS
             $(document).ready(function() {
               var infoHtml = '#{escape_javascript(info_html)}';
               var $info = $(infoHtml);
               
               var movePathInfo = function() {
                 if ($('#subwikifiles_path_info').length > 0) return; // Already present
                 
                 // Try to insert after comments field
                 // Selectors: #wiki_page_comments (standard), #content_comments (observed)
                 var commentField = $('#wiki_page_comments, #content_comments').first();
                 var target = commentField.closest('p');
                 
                 if (target.length) {
                   target.after($info);
                   console.log('RedmineSubwikifiles: Injected path info after comments');
                 } else {
                   // Fallback: prepend to attachments fields
                   // Selectors: #attachments_fields (standard), #new-attachments (observed)
                   var attachments = $('#attachments_fields, #new-attachments').first();
                   if (attachments.length) {
                      attachments.before($info);
                      console.log('RedmineSubwikifiles: Injected path info before attachments');
                   } else {
                      // Final fallback: append to form
                      var form = $('#wiki_form');
                      if (form.length) {
                        form.append($info);
                        console.log('RedmineSubwikifiles: Injected path info at end of form');
                      }
                   }
                 }
               };
               
               setTimeout(movePathInfo, 100);
             });
           JS
           
           response += javascript_tag(path_js)
        end
      end
      
      response
    end

    # Global hook for body bottom - apparently not reliable, so logic moved to head
    def view_layouts_base_body_bottom(context = {})
      # No-op now
    end

    private

    def build_js(controller)
      return '' unless controller
      return '' unless controller.class.name == 'WikiController'
      return '' unless ['index', 'show', 'edit'].include?(controller.action_name)
      
      pending_files_json = controller.instance_variable_get(:@pending_files_json)
      return '' unless pending_files_json.present?
      
      translations = {
        fix_wiki: I18n.t('redmine_subwikifiles.tooltips.fix_wiki'),
        fix_attachment: I18n.t('redmine_subwikifiles.tooltips.fix_attachment'),
        confirm_wiki: I18n.t('redmine_subwikifiles.confirmations.fix_wiki'),
        confirm_attachment: I18n.t('redmine_subwikifiles.confirmations.fix_attachment'),
        parent_info: I18n.t('redmine_subwikifiles.confirmations.parent_info'),
        fix_failed: I18n.t('redmine_subwikifiles.errors.fix_failed')
      }
      
      js_code = <<~JS
          (function() {
            var filesData = #{pending_files_json};
            var i18n = #{translations.to_json};
            
            // Inject CSS for the button (same design as folder-action-btn)
            var style = document.createElement('style');
            style.innerHTML = `
              .fix-file-btn {
                color: #fff !important;
                text-decoration: none !important;
                margin: 0 2px;
                font-size: 0.9em;
                cursor: pointer;
                padding: 0px 7px;
                border: none;
                border-radius: 3px;
                display: inline-block;
                transition: background-color 0.2s;
                background-color: #28a745;
              }
              .fix-file-btn:hover {
                background-color: #218838;
                text-decoration: none !important;
                color: #fff !important;
              }
            `;
            document.head.appendChild(style);
            
            function createFixButton(filename, type) {
              var btn = document.createElement('a');
              btn.href = 'javascript:void(0)'; // Prevent navigation
              btn.className = 'fix-file-btn';
              
              // Tooltip
              var tooltip = type === 'wiki' ? i18n.fix_wiki : i18n.fix_attachment;
              btn.title = tooltip;
              
              btn.addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation(); // Stop bubbling just in case
                console.log('Fix button clicked', filename, type);
                // alert('Debug: Button clicked for ' + filename); 
                
                if (btn.getAttribute('data-working')) return;
                
                var pathParts = location.pathname.split('/');
                var projectIndex = pathParts.indexOf('projects');
                var projectId = projectIndex >= 0 ? pathParts[projectIndex + 1] : null;
                
                var pageId = null;
                var wikiIndex = pathParts.indexOf('wiki');
                if (wikiIndex >= 0 && pathParts.length > wikiIndex + 1) {
                  pageId = pathParts[wikiIndex + 1];
                }
                
                var confirmMsg;
                if (type === 'wiki') {
                  confirmMsg = i18n.confirm_wiki.replace('%{file}', filename);
                  if (pageId) {
                     confirmMsg += "\\n" + i18n.parent_info.replace('%{parent}', decodeURIComponent(pageId));
                  }
                } else {
                  confirmMsg = i18n.confirm_attachment.replace('%{file}', filename);
                }
                
                if (!confirm(confirmMsg)) return;
                
                // Check if we're in edit mode
                var textarea = document.querySelector('textarea#content_text');
                var isEditMode = textarea && textarea.offsetParent !== null; // offsetParent check ensures it's visible
                var cursorPosition = isEditMode ? textarea.selectionStart : null;
                
                btn.setAttribute('data-working', 'true');
                btn.style.opacity = '0.5';
                btn.innerHTML = ' ...';
                
                if (type === 'attachment' && !pageId) {
                  if (wikiIndex >= 0 && pathParts.length > wikiIndex + 1) {
                     pageId = pathParts[wikiIndex + 1];
                  }
                }

                var url = type === 'wiki' ? 
                  '/projects/' + projectId + '/subwikifiles/fix_frontmatter' :
                  '/projects/' + projectId + '/subwikifiles/attach_file';
                  
                var body = type === 'wiki' ? 
                  JSON.stringify({ files: [filename], page_id: pageId }) :
                  JSON.stringify({ file: filename, page_id: pageId });
                
                var tokenMeta = document.querySelector('meta[name="csrf-token"]');
                var csrfToken = tokenMeta ? tokenMeta.content : null;

                console.log('RedmineSubwikifiles: Sending request to ' + url, body);
                fetch(url, {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': csrfToken
                  },
                  body: body
                })
                .then(function(r) { 
                  console.log('RedmineSubwikifiles: Received response status ' + r.status);
                  return r.json(); 
                })
                .then(function(data) {
                  console.log('RedmineSubwikifiles: Response data', data);
                  if ((data.fixed && data.fixed.length > 0) || data.success) {
                    // If in edit mode, insert link at cursor
                    if (isEditMode) {
                      var link = '';
                      
                      if (type === 'wiki') {
                        // Wiki page link
                        link = '[[' + filename + ']]';
                      } else {
                        // Attachment link - check if it's an image
                        var imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'svg', 'bmp'];
                        var ext = filename.split('.').pop().toLowerCase();
                        
                        if (imageExtensions.indexOf(ext) >= 0) {
                          // Inline image (Markdown syntax)
                          link = '![](' + filename + ')';
                        } else {
                          // Regular attachment link
                          link = '[' + filename + '](attachment:' + filename + ')';
                        }
                      }
                      
                      var textBefore = textarea.value.substring(0, cursorPosition);
                      var textAfter = textarea.value.substring(cursorPosition);
                      textarea.value = textBefore + link + textAfter;
                      
                      // Move cursor after the inserted link
                      textarea.selectionStart = textarea.selectionEnd = cursorPosition + link.length;
                      textarea.focus();
                      
                      // Robust removal logic
                      var entry = btn.closest('.orphan-file-entry');
                      var flashWarning = btn.closest('.flash.warning');
                      
                      if (entry) {
                        // 1. Clean up adjacent commas and spaces
                        var parent = entry.parentNode;
                        var nodes = Array.from(parent.childNodes);
                        var index = nodes.indexOf(entry);
                        
                        // Check following node for comma
                        if (index < nodes.length - 1) {
                          var next = nodes[index + 1];
                          if (next.nodeType === 3 && /^\s*,/.test(next.nodeValue)) {
                            next.nodeValue = next.nodeValue.replace(/^\s*,\s*/, ' ');
                          }
                        } 
                        // If no next comma, check previous node for comma (if it was the last item)
                        else if (index > 0) {
                          var prev = nodes[index - 1];
                          if (prev.nodeType === 3 && /,\s*$/.test(prev.nodeValue)) {
                            prev.nodeValue = prev.nodeValue.replace(/\s*,\s*$/, ' ');
                          }
                        }
                        
                        // 2. Decrement the count in the flash message text
                        if (flashWarning) {
                          var walker = document.createTreeWalker(flashWarning, NodeFilter.SHOW_TEXT, null, false);
                          var textNode;
                          while (textNode = walker.nextNode()) {
                            // Look for "X files" or "X Dateien"
                            var match = textNode.nodeValue.match(/(\\d+)\s+(files|Datei(en)?)/i);
                            if (match) {
                              var count = parseInt(match[1]);
                              if (count > 0) {
                                textNode.nodeValue = textNode.nodeValue.replace(match[0], (count - 1) + ' ' + match[2]);
                              }
                              break;
                            }
                          }
                        }

                        // 3. Remove the entry span (contains filename, error, and button)
                        entry.remove();
                        
                        // 4. Check if flash should be removed (no more orphan entries)
                        if (flashWarning && !flashWarning.querySelector('.orphan-file-entry')) {
                          flashWarning.remove();
                        }
                      }
                    } else {
                      // View mode: remove entry without reload
                      var entry = btn.closest('.orphan-file-entry');
                      var flashWarning = btn.closest('.flash.warning');
                      
                      if (entry) {
                        entry.remove();
                      }
                      
                      if (flashWarning && !flashWarning.querySelector('.orphan-file-entry')) {
                        flashWarning.remove();
                      }
                    }
                  } else if (data.failed && data.failed.length > 0) {
                    var errorMsg = data.failed.map(function(f) { 
                        return f.file + ': ' + (f.error || 'Unknown error'); 
                    }).join('\\n');
                    alert(i18n.fix_failed + '\\n' + errorMsg);
                    
                    btn.removeAttribute('data-working');
                    btn.style.opacity = '1';
                    btn.innerHTML = '✓';
                  } else {
                    alert('Error: ' + (data.error || 'Unknown error'));
                    btn.removeAttribute('data-working');
                    btn.style.opacity = '1';
                    btn.innerHTML = '✓';
                  }
                })
                .catch(function(err) {
                  alert('Error: ' + err.message);
                  btn.removeAttribute('data-working');
                  btn.style.opacity = '1';
                  btn.innerHTML = '✓';
                });
              });
              
              return btn;
            }
            
            document.addEventListener('DOMContentLoaded', function() {
              var flashWarning = document.querySelector('.flash.warning');
              if (!flashWarning || !filesData || filesData.length === 0) return;
              
              // Prevent duplicate injection
              if (flashWarning.querySelector('.fix-file-btn')) return;

              filesData.forEach(function(fileInfo) {
                var filename = fileInfo.file;
                var safeId = fileInfo.id;
                var type = fileInfo.type; // 'wiki' or 'attachment'
                
                var btn = createFixButton(filename, type);
                
                // Find our wrapped span using safeId
                var selector = '.orphan-file-entry[data-file-id="' + safeId + '"]';
                var entry = flashWarning.querySelector(selector);
                
                if (entry) {
                   btn.innerHTML = '✓';
                   entry.appendChild(btn);
                } else {
                   // Fallback for cases where server-side wrapping might have missed something
                   console.log('RedmineSubwikifiles: Span for ' + filename + ' (' + safeId + ') not found. Falling back to text search.');
                   
                   var walker = document.createTreeWalker(flashWarning, NodeFilter.SHOW_TEXT, null, false);
                   var node;
                   while(node = walker.nextNode()) {
                     var text = node.nodeValue;
                     var index = text.indexOf(filename);
                     if (index >= 0) {
                        // Greedily look for following error message in parentheses: " (missing ...)"
                        var remainingText = text.substring(index + filename.length);
                        var errorMatch = remainingText.match(/^ \([^)]+\)/);
                        var wrapLength = filename.length + (errorMatch ? errorMatch[0].length : 0);
                        
                        var filenameNode = node.splitText(index);
                        var nextPart = filenameNode.splitText(wrapLength);
                        
                        var container = document.createElement('span');
                        container.className = 'orphan-file-entry';
                        if (safeId) container.setAttribute('data-file-id', safeId);
                        
                        container.appendChild(filenameNode);
                        container.appendChild(btn);
                        
                        node.parentNode.insertBefore(container, nextPart);
                        break;
                     }
                   }
                }
              });
            });
          })();
      JS
      
      js_code.html_safe
    end
    
    def build_folder_js(controller)
      return '' unless controller
      
      # Get project from controller context (may be nil for /projects/ page)
      project = controller.instance_variable_get(:@project)
      
      # Check if we're on the projects list page
      is_projects_list = controller.controller_name == 'projects' && controller.action_name == 'index' && project.nil?
      
      Rails.logger.info "RedmineSubwikifiles: build_folder_js called, is_projects_list=#{is_projects_list}, project=#{project&.identifier}"
      
      # Collect all unassigned folders from relevant locations
      all_folders = []
      
      if project
        # Check permissions for this project
        if User.current.allowed_to?(:manage_subwikifiles, project) || User.current.admin?
          # Scan this project's directory
          folder_scanner = RedmineSubwikifiles::FolderScanner.new(project)
          project_folders = folder_scanner.scan_all_folders
          Rails.logger.info "RedmineSubwikifiles: Found #{project_folders.count} folders in project #{project.identifier}"
          project_folders.each do |f|
            f[:parent_project] = project
            f[:parent_project_id] = project.id
          end
          all_folders.concat(project_folders)
        end
      else
        # Only scan for global/top-level folders on /projects/ page
        if is_projects_list
          Rails.logger.info "RedmineSubwikifiles: Scanning for global and project folders"
          if User.current.admin? || User.current.allowed_to?(:add_project, nil, global: true)
            # First, scan for top-level folders
            folder_scanner = RedmineSubwikifiles::FolderScanner.new(nil)
            global_folders = folder_scanner.scan_all_folders
            global_folders.each do |f|
              f[:parent_project] = nil
              f[:parent_project_id] = nil
            end
            all_folders.concat(global_folders)
          end
        
          # Check if plugin is globally enabled
          globally_enabled = Setting.plugin_redmine_subwikifiles['enabled']
          
          # Scan all projects (if globally enabled) or only those with module enabled
          Project.active.each do |proj|
            has_module = proj.module_enabled?(:redmine_subwikifiles)
            
            next unless has_module || globally_enabled
            next unless User.current.allowed_to?(:manage_subwikifiles, proj) || User.current.admin?
            
            folder_scanner = RedmineSubwikifiles::FolderScanner.new(proj)
            project_folders = folder_scanner.scan_all_folders
            Rails.logger.info "RedmineSubwikifiles: Found #{project_folders.count} folders in project #{proj.identifier}"
            project_folders.each do |f|
              f[:parent_project] = proj
              f[:parent_project_id] = proj.id
            end
            all_folders.concat(project_folders)
          end
        end
      end
      
      Rails.logger.info "RedmineSubwikifiles: Total folders found: #{all_folders.count}"
      return '' if all_folders.empty?
      
      folder_data = all_folders.map do |f|
        safe_id = Base64.strict_encode64("#{f[:parent_project]&.identifier || 'global'}-#{f[:name]}").gsub(/[^a-zA-Z0-9]/, '')
        {
          name: f[:name],
          path: f[:path],
          id: safe_id,
          project_id: f[:parent_project]&.identifier,
          parent_name: f[:parent_project]&.name,
          parent_db_id: f[:parent_project_id]
        }
      end
      
      pending_folders_json = folder_data.to_json
      is_projects_list_json = is_projects_list ? 'true' : 'false'
      
      translations = {
        create_subproject: I18n.t('redmine_subwikifiles.folder_sync.create_subproject'),
        move_to_orphaned: I18n.t('redmine_subwikifiles.folder_sync.move_to_orphaned'),
        pending_folders: I18n.t('redmine_subwikifiles.folder_sync.pending_folders', details: '%{details}', count: folder_data.count)
      }
      
      js_code = <<~JS
          (function() {
            var foldersData = #{pending_folders_json};
            var i18n = #{translations.to_json};
            var isProjectsList = #{is_projects_list_json};
            
            // Inject CSS for folder buttons
            var style = document.createElement('style');
            style.innerHTML = `
              .folder-action-btn {
                color: #fff !important;
                text-decoration: none !important;
                margin: 0 2px;
                font-size: 0.9em;
                cursor: pointer;
                padding: 0px 7px;
                border: none;
                border-radius: 3px;
                display: inline-block;
                transition: background-color 0.2s;
              }
              .folder-action-btn.create-btn {
                background-color: #28a745;
              }
              .folder-action-btn.create-btn:hover {
                background-color: #218838;
              }
              .folder-action-btn.orphan-btn {
                background-color: #6c757d;
              }
              .folder-action-btn.orphan-btn:hover {
                background-color: #5a6268;
              }
              .folder-warning-flash {
                background-color: #d1ecf1;
                border-left: 4px solid #17a2b8;
                color: #0c5460;
              }
              .unassigned-folder-row {
                background-color: #f8f9fa;
              }
              .unassigned-folder-row td {
                color: #6c757d;
                font-style: italic;
              }
              .unassigned-folder-row .folder-name {
                color: #495057;
                font-style: normal;
              }
            `;
            document.head.appendChild(style);
            
            function createFolderButtons(folderName, folderPath, safeId, projectId) {
              var container = document.createElement('span');
              container.className = 'folder-action-buttons';
              
              // Create subproject button
              var createBtn = document.createElement('a');
              createBtn.href = 'javascript:void(0)';
              createBtn.className = 'folder-action-btn create-btn';
              createBtn.innerHTML = '✓';
              createBtn.title = i18n.create_subproject;
              
              // Orphan button
              var orphanBtn = document.createElement('a');
              orphanBtn.href = 'javascript:void(0)';
              orphanBtn.className = 'folder-action-btn orphan-btn';
              orphanBtn.innerHTML = '✗';
              orphanBtn.title = i18n.move_to_orphaned;
              
              // Use projectId from folder data, or extract from URL if not available
              var targetProjectId = projectId;
              if (!targetProjectId) {
                var pathParts = location.pathname.split('/');
                var projectIndex = pathParts.indexOf('projects');
                targetProjectId = projectIndex >= 0 && pathParts.length > projectIndex + 1 ? pathParts[projectIndex + 1] : null;
              }
              
              // Hide buttons if no project context (global folders need different handling)
              if (!targetProjectId) {
                container.innerHTML = '<em style="font-size:0.8em;color:#666;">(use folder prompt)</em>';
                return container;
              }
              
              createBtn.addEventListener('click', function(e) {
                e.preventDefault();
                if (createBtn.getAttribute('data-working')) return;
                
                createBtn.setAttribute('data-working', 'true');
                createBtn.style.opacity = '0.5';
                createBtn.innerHTML = '...';
                
                var tokenMeta = document.querySelector('meta[name="csrf-token"]');
                var csrfToken = tokenMeta ? tokenMeta.content : null;
                
                fetch('/projects/' + targetProjectId + '/subwikifiles/create_subproject_from_folder', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': csrfToken
                  },
                  body: JSON.stringify({ folder_name: folderName, folder_path: folderPath })
                })
                .then(function(r) {
                  if (!r.ok) {
                    return r.text().then(function(text) {
                      try { return JSON.parse(text); } catch(e) { throw new Error('Server error (' + r.status + ')'); }
                    });
                  }
                  return r.json();
                })
                .then(function(data) {
                  if (data.success) {
                    // Redirect to new project settings
                    window.location.href = '/projects/' + data.project_id + '/settings';
                  } else {
                    alert('Error: ' + (data.error || 'Unknown error'));
                    createBtn.removeAttribute('data-working');
                    createBtn.style.opacity = '1';
                    createBtn.innerHTML = '✓';
                  }
                })
                .catch(function(err) {
                  alert('Error: ' + err.message);
                  createBtn.removeAttribute('data-working');
                  createBtn.style.opacity = '1';
                  createBtn.innerHTML = '✓';
                });
              });
              
              orphanBtn.addEventListener('click', function(e) {
                e.preventDefault();
                if (orphanBtn.getAttribute('data-working')) return;
                
                orphanBtn.setAttribute('data-working', 'true');
                orphanBtn.style.opacity = '0.5';
                orphanBtn.innerHTML = '...';
                
                var tokenMeta = document.querySelector('meta[name="csrf-token"]');
                var csrfToken = tokenMeta ? tokenMeta.content : null;
                
                fetch('/projects/' + targetProjectId + '/subwikifiles/orphan_folder', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': csrfToken
                  },
                  body: JSON.stringify({ folder_name: folderName, folder_path: folderPath })
                })
                .then(function(r) {
                  if (!r.ok) {
                    return r.text().then(function(text) {
                      try { return JSON.parse(text); } catch(e) { throw new Error('Server error (' + r.status + ')'); }
                    });
                  }
                  return r.json();
                })
                .then(function(data) {
                  if (data.success) {
                    var entry = container.closest('.orphan-folder-entry');
                    var flashBox = container.closest('.flash');
                    
                    if (entry) entry.remove();
                    if (flashBox && !flashBox.querySelector('.orphan-folder-entry')) {
                      flashBox.remove();
                    }
                  } else {
                    alert('Error: ' + (data.error || 'Unknown error'));
                    orphanBtn.removeAttribute('data-working');
                    orphanBtn.style.opacity = '1';
                    orphanBtn.innerHTML = '✗';
                  }
                })
                .catch(function(err) {
                  alert('Error: ' + err.message);
                  orphanBtn.removeAttribute('data-working');
                  orphanBtn.style.opacity = '1';
                  orphanBtn.innerHTML = '✗';
                });
              });
              
              container.appendChild(createBtn);
              container.appendChild(orphanBtn);
              return container;
            }
            
            // Inject folders into table view
            function injectIntoTable(projectTable, folders) {
              var foldersByParent = {};
              folders.forEach(function(f) {
                var key = f.parent_db_id || 'root';
                if (!foldersByParent[key]) foldersByParent[key] = [];
                foldersByParent[key].push(f);
              });
              
              var existingRow = projectTable.querySelector('tr');
              var colCount = existingRow ? existingRow.querySelectorAll('td').length : 3;
              
              Object.keys(foldersByParent).forEach(function(parentKey) {
                var folderList = foldersByParent[parentKey];
                var insertAfter = null;
                var indentLevel = 0;
                
                if (parentKey !== 'root') {
                  var parentRow = document.getElementById('project-' + parentKey);
                  if (parentRow) {
                    insertAfter = parentRow;
                    var parentClasses = parentRow.className.match(/idnt-(\d+)/);
                    indentLevel = parentClasses ? parseInt(parentClasses[1]) + 1 : 1;
                  }
                }
                
                folderList.forEach(function(folderInfo) {
                  var row = document.createElement('tr');
                  row.className = 'unassigned-folder-row' + (indentLevel > 0 ? ' idnt idnt-' + indentLevel : '');
                  row.setAttribute('data-folder-id', folderInfo.id);
                  
                  var nameCell = document.createElement('td');
                  nameCell.className = 'name';
                  nameCell.innerHTML = '<span class="folder-name">📁 ' + folderInfo.name + '</span> ';
                  nameCell.appendChild(createFolderButtons(folderInfo.name, folderInfo.path, folderInfo.id, folderInfo.project_id));
                  row.appendChild(nameCell);
                  
                  for (var i = 1; i < colCount; i++) {
                    var emptyCell = document.createElement('td');
                    emptyCell.innerHTML = '—';
                    row.appendChild(emptyCell);
                  }
                  
                  if (insertAfter) {
                    insertAfter.parentNode.insertBefore(row, insertAfter.nextElementSibling);
                    insertAfter = row;
                  } else {
                    projectTable.appendChild(row);
                  }
                });
              });
            }
            
            // Inject folders into board view (nested lists)
            function injectIntoBoard(projectBoard, folders) {
              var foldersByParent = {};
              folders.forEach(function(f) {
                var key = f.parent_db_id || 'root';
                if (!foldersByParent[key]) foldersByParent[key] = [];
                foldersByParent[key].push(f);
              });
              
              Object.keys(foldersByParent).forEach(function(parentKey) {
                var folderList = foldersByParent[parentKey];
                var targetList = null;
                
                if (parentKey === 'root') {
                  // Find or create root list
                  targetList = projectBoard.querySelector(':scope > ul.projects.root');
                  if (!targetList) {
                    targetList = projectBoard.querySelector(':scope > ul');
                  }
                } else {
                  // Find parent project's child list
                  var parentLink = projectBoard.querySelector('a.project[href*="/' + folderList[0].project_id + '"]');
                  if (parentLink) {
                    var parentLi = parentLink.closest('li');
                    if (parentLi) {
                      targetList = parentLi.querySelector(':scope > ul.projects');
                      if (!targetList) {
                        targetList = document.createElement('ul');
                        targetList.className = 'projects';
                        parentLi.appendChild(targetList);
                      }
                    }
                  }
                }
                
                if (!targetList) {
                  targetList = projectBoard.querySelector('ul.projects') || projectBoard;
                }
                
                folderList.forEach(function(folderInfo) {
                  var li = document.createElement('li');
                  li.className = 'child unassigned-folder-row';
                  li.setAttribute('data-folder-id', folderInfo.id);
                  
                  var span = document.createElement('span');
                  span.className = 'folder-name';
                  span.innerHTML = folderInfo.name + ' ';
                  span.appendChild(createFolderButtons(folderInfo.name, folderInfo.path, folderInfo.id, folderInfo.project_id));
                  
                  li.appendChild(span);
                  targetList.appendChild(li);
                });
              });
            }
            
            document.addEventListener('DOMContentLoaded', function() {
              if (!foldersData || foldersData.length === 0) return;
              
              // Prevent duplicate injection
              if (document.querySelector('.folder-warning-flash') || document.querySelector('.unassigned-folder-row')) return;
              
              if (isProjectsList) {
                // On /projects/ page: inject into project list
                var projectTable = document.querySelector('table.list.projects tbody');
                var projectBoard = document.getElementById('projects-index');
                
                if (projectTable) {
                  injectIntoTable(projectTable, foldersData);
                } else if (projectBoard) {
                  injectIntoBoard(projectBoard, foldersData);
                }
              } else {
                // On other pages: show flash message
                var entriesHtml = foldersData.map(function(f) {
                  var label = f.parent_name ? (f.parent_name + ' / ' + f.name) : f.name;
                  return '<span class="orphan-folder-entry" data-folder-id="' + f.id + '">📁 ' + label + '</span>';
                }).join(', ');
                
                var flashBox = document.createElement('div');
                flashBox.className = 'flash notice folder-warning-flash';
                flashBox.innerHTML = '<div class="folder-warning-content">' + 
                  i18n.pending_folders.replace('%{details}', entriesHtml) + '</div>';
                
                var content = document.getElementById('content');
                if (content) {
                  content.insertBefore(flashBox, content.firstChild);
                }
                
                foldersData.forEach(function(folderInfo) {
                  var selector = '.orphan-folder-entry[data-folder-id="' + folderInfo.id + '"]';
                  var entry = flashBox.querySelector(selector);
                  if (entry) {
                    entry.appendChild(createFolderButtons(folderInfo.name, folderInfo.path, folderInfo.id, folderInfo.project_id));
                  }
                });
              }
            });
          })();
      JS
      
      js_code.html_safe
    end
    
    # Remove body hook as head is sufficient
    def view_layouts_base_body_bottom(context={})
      ''
    end
  end
end
