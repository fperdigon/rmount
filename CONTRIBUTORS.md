# Contributors

RMount exists because of the people below. The complete, always current list is on the
[contributors graph](https://github.com/fperdigon/rmount/graphs/contributors).

## Original author

- **[Ayon Pal](https://github.com/AyonPal)**: created [macsh](https://github.com/AyonPal/macsh),
  the project RMount is forked from: the rclone-based architecture, the menu bar app, the SFTP,
  S3 and FTP backends, key generation and the first releases.

## Maintainer of the fork

- **[Francisco Perdigon Romero](https://github.com/fperdigon)** ([Core AI](https://core-ai.net)):
  CI and releases, in-app updates, async mount and unmount, NFS performance, per-remote tuning,
  more backends (SMB, WebDAV/Nextcloud, Google Drive, Azure, B2, GCS, raw rclone options),
  `rclone.conf` import, test coverage.

## Who wrote the code

Lines of code, text files only (code, tests, scripts, docs, workflows), measured at commit `5e451e9`.
Only humans are listed. A commit authored by Claude Code goes to the human who was working on the
project at that moment: all 34 of them were made between 2026-10-16 and 2026-10-17, during the
maintainer's work (started 2026-10-14), none during the original author's (2026-05-04 to 2026-05-07).
The original author used Claude too; that shows as a `Co-authored-by` trailer on his own commits, which
are already his. Claude stays credited as co-author in the commit messages and history is untouched.

| Author | Lines in the code today | Lines added over the history |
| --- | --- | --- |
| Francisco Perdigon Romero | 9,773 (73.2%) | 10,623 |
| Ayon Pal (original macsh author) | 3,587 (26.8%) | 3,861 |

Regenerate with `scripts/authorship.sh` (`--raw` shows Claude's commits separately). Surviving lines
come from `git blame`, ignoring whitespace, moved lines and the mechanical macsh to RMount rename
(`.git-blame-ignore-revs`), so the rename does not take Ayon's lines away from him.

## Third-party software

- [rclone](https://rclone.org) and its contributors, whose work does the actual mounting.

## Want to be listed?

Open a pull request. Add yourself here in the same PR, with a one-line description of what you did.
