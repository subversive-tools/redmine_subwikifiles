# Redmine Subwikifiles Plugin

![Version](https://img.shields.io/badge/version-0.4.0-blue.svg)
![Redmine](https://img.shields.io/badge/Redmine-5.0%20%7C%206.0-red.svg?logo=redmine)
![License](https://img.shields.io/badge/license-MIT-green.svg)

Redmine Subwikifiles enables bidirectional synchronization between Redmine Wiki pages and local Markdown files. Edit your documentation in an external editor of your choice; the plugin handles the structure, detects orphan files and folders, and automatically versions changes via Git. Ideal for teams that want to manage their documentation within the filesystem.

---

## Features

- **File Storage**: Wiki pages are saved as Markdown files (`.md`) in a configurable directory.
- **Bidirectional Sync**:
    -   **Write**: Saving a Wiki page in Redmine writes to the filesystem.
    -   **Read**: Viewing a Wiki page reads from the filesystem if the file is newer than the database record.
- **Hierarchical Structure**: Wiki page hierarchy is represented by folders in the filesystem.
- **Git Integration**: Automatically commits changes to a Git repository in the storage directory.
- **Attachment Handling**: Syncs attachments between Redmine and a local `_attachments` folder.
- **Conflict Detection**: Detects if the file on disk is newer than the database version.
- **Folder Detection**: Automatically detects new folders and offers inline buttons to create subprojects or ignore them.
- **Orphan File Handling**: Detects orphan files (missing frontmatter) and provides fix buttons.

## Screenshots

<img width="452" height="253" alt="screenshot1" src="https://github.com/user-attachments/assets/44d7ec5f-6c9f-4958-af87-dfd60a992f6d" />
<img width="850" height="340" alt="screenshot2" src="https://github.com/user-attachments/assets/7753e67c-d227-4082-9ada-310d7c443fcf" />
<img width="834" height="393" alt="screenshot3" src="https://github.com/user-attachments/assets/201b93ae-9ecc-4047-9209-6f8a86e6037c" />


## Installation

> [!IMPORTANT]
> The plugin directory **MUST** be named `redmine_subwikifiles` for assets to load correctly.

1.  **Clone the repository** into your plugins directory:
    ```bash
    cd /path/to/redmine/plugins
    git clone https://github.com/modoq/redmine_subwikifiles.git redmine_subwikifiles
    ```

2.  **Restart Redmine**.
    ```bash
    # Docker
    docker-compose restart redmine
    
    # Or for local installations
    touch tmp/restart.txt
    ```

3.  **Configure the plugin** in Administration -> Plugins.

## Configuration

Navigate to **Administration > Plugins > Redmine Subwikifiles > Configure**.

### General Settings

| Option | Description |
|:---|:---|
| **Enabled** | Enable globally. If enabled, the plugin is active for all projects. If disabled, it can be enabled per project (subprojects automatically inherit the feature). |
| **Base Path** | The root directory for storing wiki files (default: `/var/lib/redmine/wiki_files`). |
| **Git Enabled** | Enable automatic Git commits when saving pages. |
| **Conflict Strategy** | Defines behavior when file is newer than DB. <br> - `file_wins`: File content overwrites DB content. <br> - `manual`: Logs a warning (future: merge markers). |

> [!WARNING]
> **Filesystem Permissions**: Redmine permissions are **NOT** propagated to the filesystem. Folders and files on disk do NOT correspond to Redmine project members/roles. Access to the files is governed solely by the operating system user running Redmine.

## Directory Structure

Files are stored in `{base_path}/{Project Name}/`.
Hierarchy is represented by folders.

```
Project Name/
├── .project
├── Wiki.md
├── Parent_Page.md
├── Child_Page.md
├── _attachments/
│   └── Page_Title/
│       └── image.png
├── _orphaned/
└── Subproject Name/
    ├── .project
    └── Wiki.md
```

## Contributing

Contributions are welcome! Please fork the repository and submit a Pull Request.

1.  Fork it
2.  Create your feature branch (`git checkout -b feature/my-new-feature`)
3.  Commit your changes (`git commit -am 'Add some feature'`)
4.  Push to the branch (`git push origin feature/my-new-feature`)
5.  Create a new Pull Request

## License

This plugin is open source software licensed under the [MIT license](LICENSE).
