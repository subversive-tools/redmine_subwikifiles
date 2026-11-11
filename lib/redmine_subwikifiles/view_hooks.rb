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
           base_dir = RedmineSubwikifiles.base_path
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
                      textarea.dispatchEvent(new Event('input', { bubbles: true }));
                      
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
      
      # NEW SCOPE RESTRICTION: Only offer folders if we are on /projects or under a specific project
      unless project || is_projects_list || is_new_project_page
        Rails.logger.debug "RedmineSubwikifiles: Skipping folder notice (not on a projects page)"
        return ''
      end
      
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
      elsif is_projects_list || is_new_project_page
        # Scenario B: Global Context / Project List -> Scan global and/or all projects
        
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
      
      project_names = Project.where(identifier: all_folders.map { |f| f[:parent_project_id] }.compact.uniq).pluck(:identifier, :name).to_h
      folder_data = all_folders.map do |f|
        safe_id = Base64.strict_encode64("#{f[:parent_project_id] || 'global'}-#{f[:name]}").gsub(/[^a-zA-Z0-9]/, '')
        {
          id: safe_id,
          name: f[:name],
          path: f[:path],
          project_id: f[:parent_project_id],
          project_name: project_names[f[:parent_project_id]]
        }
      end

      # Icons/buttons rendered like Redmine's own links so every theme styles them
      view = controller.view_context
      icon = ->(name, label) { view.respond_to?(:sprite_icon) ? view.sprite_icon(name, label).to_s : ERB::Util.html_escape(label) }
      t = ->(k, **o) { I18n.t("redmine_subwikifiles.folder_ui.#{k}", **o) }
      only_parent = folder_data.map { |f| f[:project_id] }.uniq
      title =
        if only_parent.size == 1 && only_parent.first
          t.(:title_project, count: folder_data.size, project: project_names[only_parent.first])
        else
          t.(:title_global, count: folder_data.size)
        end
      ui = {
        title: title,
        create: t.(:create),
        create_html: icon.('add', t.(:create)),
        ignore_html: icon.('close', t.(:ignore)),
        folder_html: view.respond_to?(:sprite_icon) ? view.sprite_icon('folder').to_s : '',
        create_tip_global: t.(:create_tip_global),
        create_tip_sub: t.(:create_tip_sub),
        ignore_tip: t.(:ignore_tip),
        in_project: t.(:in_project),
        created: t.(:created),
        ignored: t.(:ignored),
        working: t.(:working),
        error: t.(:error)
      }

      js_code = <<~JS
        /* RedmineSubwikifiles: new folder question */
        (function() {
          if (window.swFolderPrompt) return;
          window.swFolderPrompt = true;
          var folders = #{folder_data.to_json};
          var ui = #{ui.to_json};

          function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
          function fmt(s, v) { return String(s || '').replace(/%\\{(\\w+)\\}/g, function (_, k) { return v[k] != null ? v[k] : ''; }); }

          function projectContext(f) {
            if (f.project_id) return f.project_id;
            var parts = location.pathname.split('/'), idx = parts.indexOf('projects');
            var p = idx >= 0 && parts.length > idx + 1 ? parts[idx + 1] : null;
            return (p === 'new' || p === 'wiki') ? null : p;
          }

          function post(url, body) {
            var meta = document.querySelector('meta[name="csrf-token"]');
            return fetch(url, {
              method: 'POST', credentials: 'same-origin',
              headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': meta ? meta.content : '' },
              body: JSON.stringify(body)
            }).then(function (r) { return r.json(); });
          }

          function addSidebarProject(name, identifier, parentIdentifier) {
            var sidebar = document.querySelector('#mini-wiki-sidebar');
            if (!sidebar) return;
            var targetUl;
            if (parentIdentifier) {
              var parentLink = sidebar.querySelector('a.type-project[href$="/projects/' + parentIdentifier + '"]');
              var parentLi = parentLink && parentLink.closest('li');
              if (!parentLi) return;
              var uls = Array.from(parentLi.children).filter(function (c) { return c.tagName === 'UL'; });
              targetUl = uls.length >= 2 ? uls[1] : (uls.length === 1 && uls[0].querySelector('a.type-project') ? uls[0] : null);
              if (!targetUl) { targetUl = document.createElement('ul'); parentLi.appendChild(targetUl); }
            } else {
              targetUl = sidebar.querySelector('.mini-wiki-sidebar-content > ul');
            }
            if (!targetUl) return;
            var li = document.createElement('li');
            li.className = 'expanded';
            var iconHref = ((sidebar.querySelector('use') || { getAttribute: function () { return ''; } }).getAttribute('href') || '').split('#')[0] + '#icon--folder';
            li.innerHTML = '<div class="node-label-container"><span class="expand-icon-spacer"></span>' +
              '<a class="wiki-page-link type-project" href="/projects/' + esc(identifier) + '">' +
              '<svg class="subnav-icon subnav-icon-folder" aria-hidden="true"><use href="' + iconHref + '"></use></svg>' +
              '<span>' + esc(name) + '</span></a></div>';
            targetUl.appendChild(li);
          }

          function finish(row, html) {
            row.querySelector('.swf-folder-actions').innerHTML = html;
            row.classList.add('swf-folder-done');
          }

          function act(row, f, kind) {
            var actions = row.querySelector('.swf-folder-actions');
            if (actions.getAttribute('data-working')) return;
            actions.setAttribute('data-working', '1');
            var msg = row.querySelector('.swf-folder-msg');
            msg.textContent = ui.working;
            var ctx = projectContext(f);
            var base = ctx ? '/projects/' + encodeURIComponent(ctx) + '/subwikifiles/' : '/subwikifiles/';
            var url = base + (kind === 'create' ? 'create_subproject_from_folder' : 'orphan_folder');
            post(url, { folder_name: f.name, folder_path: f.path }).then(function (d) {
              if (!d.success) throw new Error(d.error || '?');
              msg.textContent = '';
              if (kind === 'create') {
                finish(row, '✓ ' + esc(ui.created) + ' <a href="/projects/' + esc(d.project_id) + '">' + esc(f.name) + '</a>');
                addSidebarProject(f.name, d.project_id, ctx);
              } else {
                finish(row, esc(ui.ignored));
              }
              var box = document.querySelector('.swf-folder-prompt');
              if (box && !box.querySelector('.swf-folder:not(.swf-folder-done)')) {
                setTimeout(function () { box.parentNode && box.parentNode.removeChild(box); }, 4000);
              }
            }).catch(function (e) {
              actions.removeAttribute('data-working');
              msg.textContent = fmt(ui.error, { error: e.message });
              msg.classList.add('swf-folder-err');
            });
          }

          function inject() {
            if (document.querySelector('.swf-folder-prompt')) return;
            var cnt = document.querySelector('#projects-index') || document.querySelector('#content');
            if (!cnt) return;
            var box = document.createElement('div');
            box.className = 'flash warning swf-folder-prompt';
            var multiParent = folders.some(function (f) { return f.project_id !== folders[0].project_id; });
            var html = '<div class="swf-folder-title">' + esc(ui.title) + '</div><ul class="swf-folder-list">';
            folders.forEach(function (f, i) {
              var tip = f.project_id ? fmt(ui.create_tip_sub, { name: f.name, project: f.project_name || f.project_id }) : fmt(ui.create_tip_global, { name: f.name });
              html += '<li class="swf-folder" data-i="' + i + '">' +
                '<span class="swf-folder-name" title="' + esc(f.path) + '">' + ui.folder_html + esc(f.name) + '</span>' +
                (multiParent && f.project_id ? '<span class="swf-folder-parent">' + esc(fmt(ui.in_project, { project: f.project_name || f.project_id })) + '</span>' : '') +
                '<span class="swf-folder-actions">' +
                  '<button type="button" class="swf-folder-create" title="' + esc(tip) + '">' + esc(ui.create) + '</button>' +
                  '<a href="#" class="icon icon-close swf-folder-ignore" title="' + esc(ui.ignore_tip) + '">' + ui.ignore_html + '</a>' +
                '</span><span class="swf-folder-msg"></span></li>';
            });
            box.innerHTML = html + '</ul>';
            cnt.insertBefore(box, cnt.firstChild);
            Array.prototype.forEach.call(box.querySelectorAll('.swf-folder'), function (row) {
              var f = folders[+row.getAttribute('data-i')];
              row.querySelector('.swf-folder-create').onclick = function () { act(row, f, 'create'); };
              row.querySelector('.swf-folder-ignore').onclick = function (e) { e.preventDefault(); act(row, f, 'ignore'); };
            });
          }

          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', inject);
          else inject();
        })();
      JS

      js_code.html_safe
    end

    # Layout only - colors, fonts, buttons and links come from Redmine / the theme
    # (box = Redmine's "flash warning", button = native button, ignore = icon link).
    def build_folder_css(controller)
      <<~CSS
        .swf-folder-prompt .swf-folder-title { font-weight: bold; margin-bottom: 4px; }
        .swf-folder-prompt .swf-folder-list { list-style: none; margin: 0; padding: 0; }
        .swf-folder-prompt .swf-folder { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; padding: 3px 0; }
        .swf-folder-prompt .swf-folder-name { display: inline-flex; align-items: center; gap: 4px; font-weight: 600; min-width: 140px; }
        .swf-folder-prompt .swf-folder-name svg { width: 16px; height: 16px; }
        .swf-folder-prompt .swf-folder-parent { opacity: .75; font-size: 0.9em; }
        .swf-folder-prompt .swf-folder-actions { display: inline-flex; align-items: center; gap: 10px; }
        .swf-folder-prompt .swf-folder-create { margin: 0; }
        .swf-folder-prompt .swf-folder-msg { opacity: .8; font-size: 0.9em; }
        .swf-folder-prompt .swf-folder-msg.swf-folder-err { opacity: 1; font-weight: 600; }
        .swf-folder-prompt .swf-folder-done .swf-folder-name { opacity: .6; }
        .swf-folder-prompt .swf-folder-actions[data-working] { opacity: .5; pointer-events: none; }
      CSS
    end
  end
end
