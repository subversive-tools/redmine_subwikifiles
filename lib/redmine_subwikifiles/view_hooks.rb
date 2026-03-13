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
      
      # 3. CSS for folder notice
      folder_css = build_folder_css(controller)
      response += content_tag(:style, folder_css.html_safe) if folder_css.present?
      
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
                  if (!r.ok) {
                    return r.text().then(function(text) {
                      try {
                        var json = JSON.parse(text);
                        throw new Error(json.error || 'Server error ' + r.status);
                      } catch(e) {
                        if (e.message.includes('Server error')) throw e;
                        throw new Error('Server error ' + r.status + ': ' + text.substring(0, 100));
                      }
                    });
                  }
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
      
      # Get project from controller context
      project = controller.instance_variable_get(:@project)
      
      # Determine context
      is_projects_list = controller.controller_name == 'projects' && controller.action_name == 'index'
      is_new_project_page = controller.controller_name == 'projects' && controller.action_name == 'new'
      
      Rails.logger.info "RedmineSubwikifiles: build_folder_js called. Context: proj_list=#{is_projects_list}, new_proj=#{is_new_project_page}, project=#{project&.identifier}"
      
      all_folders = []
      
      # FIX SCOPE: 
      # If we are in a project context, we ONLY scan that project's subfolders.
      # Global scanning is only done if we are on the project list or if user is admin.
      
      if project && !project.new_record?
        # Scenario A: Project Context -> Only scan this project
        if User.current.allowed_to?(:manage_subwikifiles, project) || User.current.admin?
          folder_scanner = RedmineSubwikifiles::FolderScanner.new(project)
          project_folders = folder_scanner.scan_all_folders
          project_folders.each do |f|
            f[:parent_project_id] = project.identifier
          end
          all_folders.concat(project_folders)
        end
      elsif is_projects_list || is_new_project_page || User.current.admin?
        # Scenario B: Global Context / Project List / Admin -> Scan global and/or all projects
        
        # 1. Scan Global
        if User.current.admin? || User.current.allowed_to?(:add_project, nil, global: true)
          folder_scanner = RedmineSubwikifiles::FolderScanner.new(nil)
          global_folders = folder_scanner.scan_all_folders
          global_folders.each do |f|
            f[:parent_project_id] = nil
          end
          all_folders.concat(global_folders)
        end
        
        # 2. Scan all projects if on index (expensive, so only done here)
        if is_projects_list
          globally_enabled = Setting.plugin_redmine_subwikifiles['enabled']
          Project.active.each do |proj|
            has_module = proj.module_enabled?(:redmine_subwikifiles)
            next unless has_module || globally_enabled
            next unless User.current.allowed_to?(:manage_subwikifiles, proj) || User.current.admin?
            
            p_scanner = RedmineSubwikifiles::FolderScanner.new(proj)
            p_folders = p_scanner.scan_all_folders
            p_folders.each { |f| f[:parent_project_id] = proj.identifier }
            all_folders.concat(p_folders)
          end
        end
      end
      
      Rails.logger.info "RedmineSubwikifiles: Total folders found: #{all_folders.count}"
      return '' if all_folders.empty?
      
      folder_data = all_folders.map do |f|
        safe_id = Base64.strict_encode64("#{f[:parent_project_id] || 'global'}-#{f[:name]}").gsub(/[^a-zA-Z0-9]/, '')
        {
          id: safe_id,
          name: f[:name],
          path: f[:path],
          project_id: f[:parent_project_id]
        }
      end

      pending_folders_json = folder_data.to_json
      translations = {
        create_subproject: I18n.t('redmine_subwikifiles.folder_sync.create_subproject'),
        move_to_orphaned: I18n.t('redmine_subwikifiles.folder_sync.move_to_orphaned'),
        pending_folders: I18n.t('redmine_subwikifiles.folder_sync.pending_folders', details: '%{details}', count: folder_data.count)
      }
      
      js_code = <<~JS
        /* RedmineSubwikifiles v126FIX */
        (function() {
          var vKey = 'sw_v126_loaded';
          if (window[vKey]) { console.log('RedmineSubwikifiles: v126FIX already running'); return; }
          window[vKey] = true;

          console.log('RedmineSubwikifiles: v126FIX Inline script starting...');
          window.sw_v126_folders = #{pending_folders_json};
          window.sw_v126_i18n = #{translations.to_json};
          
          function createSwButtons(folderName, folderPath, safeId, projectId) {
            var container = document.createElement('span');
            container.className = 'folder-action-container';
            
            // Shared fetch helper
            function swFetch(url, body, btn, successCb) {
              btn.setAttribute('data-working', 'true');
              btn.style.opacity = '0.5';
              var csrf = document.querySelector('meta[name="csrf-token"]').content;
              
              fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
                body: JSON.stringify(body)
              }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.success) {
                  successCb(d);
                  var entry = document.querySelector('.orphan-folder-entry[data-id="' + safeId + '"]');
                  if (entry) entry.remove();
                  var box = document.querySelector('.folder-warning-flash');
                  if (box && !box.querySelector('.orphan-folder-entry')) box.remove();
                } else {
                  alert('Error: ' + (d.error || 'Unknown error'));
                  btn.removeAttribute('data-working');
                  btn.style.opacity = '1';
                }
              }).catch(function(err) {
                alert('Request failed: ' + err.message);
                btn.removeAttribute('data-working');
                btn.style.opacity = '1';
              });
            }

            function swAddSidebarProject(name, identifier, parentIdentifier) {
              var sidebar = document.querySelector('#mini-wiki-sidebar');
              if (!sidebar) return;

              // Find the parent project's node explicitly
              var parentLink = sidebar.querySelector('a.type-project[href$="/projects/' + parentIdentifier + '"]') ||
                               sidebar.querySelector('a.type-project[href*="/projects/' + parentIdentifier + '"]');
              if (!parentLink) return;
              
              var parentLi = parentLink.closest('li');
              if (!parentLi) return;

              // Subprojects are traditionally in a second UL list under the project node
              // We filter only direct UL children to find the correct container
              var uls = Array.from(parentLi.children).filter(function(c) { return c.tagName === 'UL'; });
              var targetUl;
              
              if (uls.length >= 2) {
                targetUl = uls[1];
              } else if (uls.length === 1) {
                // If only one UL exists, check if it's the project list or pages list
                if (uls[0].querySelector('a.type-project')) {
                  targetUl = uls[0];
                } else {
                  targetUl = document.createElement('ul');
                  parentLi.appendChild(targetUl);
                }
              } else {
                targetUl = document.createElement('ul');
                parentLi.appendChild(targetUl);
              }

              var li = document.createElement('li');
              li.className = 'expanded';
              var iconHref = (sidebar.querySelector('use')?.getAttribute('href')?.split('#')[0] || '') + '#icon--folder';
              
              li.innerHTML = '<div class="node-label-container">' +
                '<span class="expand-icon-spacer"></span>' +
                '<a class="wiki-page-link type-project" href="/projects/' + identifier + '">' +
                '<svg class="subnav-icon subnav-icon-folder" aria-hidden="true"><use href="' + iconHref + '"></use></svg>' +
                '<span>' + name + '</span></a></div>';
              
              targetUl.appendChild(li);
            }

            // Determine project context early
            var project_context = projectId;
            if (!project_context) {
               var parts = location.pathname.split('/');
               var idx = parts.indexOf('projects');
               if (idx >= 0 && parts.length > idx + 1) project_context = parts[idx+1];
               if (project_context === 'new' || project_context === 'wiki') project_context = null;
            }

            // 1. Create (Green Check) - NOW AJAX
            var checkBtn = document.createElement('a');
            checkBtn.innerHTML = '✓';
            checkBtn.className = 'folder-action-btn create-btn';
            checkBtn.title = window.sw_v126_i18n.create_subproject;
            checkBtn.href = 'javascript:void(0)';
            
            checkBtn.addEventListener('click', function(e) {
              e.preventDefault();
              if (checkBtn.getAttribute('data-working')) return;
              if (!project_context) { alert('No project context found for creating subproject.'); return; }
              
              var url = '/projects/' + project_context + '/subwikifiles/create_subproject_from_folder';
              swFetch(url, { folder_name: folderName, folder_path: folderPath }, checkBtn, function(data) {
                console.log('RedmineSubwikifiles: AJAX project creation success for ' + folderName);
                if (data && data.project_id) {
                  swAddSidebarProject(folderName, data.project_id, project_context);
                }
              });
            });
            
            // 2. Ignore (Grey Cross)
            var ignoreBtn = document.createElement('a');
            ignoreBtn.innerHTML = '✗';
            ignoreBtn.className = 'folder-action-btn orphan-btn';
            ignoreBtn.title = window.sw_v126_i18n.move_to_orphaned;
            ignoreBtn.href = 'javascript:void(0)';
            
            ignoreBtn.addEventListener('click', function(e) {
              e.preventDefault();
              if (ignoreBtn.getAttribute('data-working')) return;
              if (!project_context) { alert('No project context found for ignoring.'); return; }
              
              var url = '/projects/' + project_context + '/subwikifiles/orphan_folder';
              swFetch(url, { folder_name: folderName, folder_path: folderPath }, ignoreBtn, function() {
                console.log('RedmineSubwikifiles: AJAX folder ignore success for ' + folderName);
              });
            });
            
            container.appendChild(checkBtn);
            container.appendChild(ignoreBtn);
            
            return container;
          }

          function swInject() {
            if (window.sw_v126_done) return;
            var cnt = document.querySelector('#projects-index') || document.querySelector('#content');
            if (!cnt) return;
            
            if (document.querySelector('.folder-warning-flash')) return;

            window.sw_v126_done = true;
            console.log('RedmineSubwikifiles: swInject started');
            
            var b = document.createElement('div');
            b.className = 'flash folder-warning-flash';
            
            var inner = '<div class="folder-warning-content">';
            inner += '<strong>' + window.sw_v126_i18n.pending_folders.replace('%{details}.', '') + '</strong>&nbsp;&nbsp;';
            window.sw_v126_folders.forEach(function(f) {
              inner += '<span class="orphan-folder-entry" data-id="' + f.id + '">' + f.name + ' </span>';
            });
            inner += '</div>';
            b.innerHTML = inner;
            
            cnt.insertBefore(b, cnt.firstChild);
            window.sw_v126_folders.forEach(function(f) {
              var e = b.querySelector('[data-id="' + f.id + '"]');
              if (e) e.appendChild(createSwButtons(f.name, f.path, f.id, f.project_id));
            });
            console.log('RedmineSubwikifiles: v126FIX Done.');
          }

          if (document.readyState === 'complete') swInject();
          window.addEventListener('load', swInject);
          document.addEventListener('turbolinks:load', swInject);
          setInterval(swInject, 3000);
        })();
      JS
      
      js_code.html_safe
    end

    def build_folder_css(controller)
      <<~CSS
        .folder-action-btn { color: #fff !important; text-decoration: none !important; margin: 0 4px; padding: 2px 8px; border-radius: 4px; display: inline-block; font-weight: bold; }
        .folder-action-btn.create-btn { background-color: #28a745; box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
        .folder-action-btn.orphan-btn { background-color: #6c757d; box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
        .folder-warning-flash { background-color: #e3f2fd !important; border: 1px solid #90caf9 !important; border-left: 5px solid #2196f3 !important; color: #0d47a1 !important; padding: 12px !important; margin-bottom: 20px !important; display: block !important; visibility: visible !important; }
        .folder-warning-content { display: flex; align-items: center; flex-wrap: wrap; }
        .orphan-folder-entry { margin-right: 15px; border-bottom: 1px dashed #2196f3; }
      CSS
    end
    
    # Remove body hook as head is sufficient
    def view_layouts_base_body_bottom(context={})
      ''
    end
  end
end
