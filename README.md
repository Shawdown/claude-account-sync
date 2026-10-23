# Claude Account Sync

Use a personal and an organization Claude account on the same Windows 11 PC while sharing all local Claude Code data between them: settings, `CLAUDE.md`, agents, commands, skills, plugins, MCP servers, trusted folders and session history.

Each account keeps only its own login. Everything else lives in one shared folder.

```
%USERPROFILE%\.claude          personal account (login + account info)
%USERPROFILE%\.claude-org      org account (login + account info)
%USERPROFILE%\.claude-shared   everything else, linked into both
```

Claude Code picks the account from the `CLAUDE_CONFIG_DIR` environment variable. Switching accounts changes that variable.

## Setup

1. Quit Claude Desktop (including its tray icon) and close VS Code, Zed and any terminal running Claude Code.
2. Double-click `setup.cmd`.
3. Open a new terminal, run `claude-org`, type `/login` and sign in with your org account.

Setup backs up your current data to `%USERPROFILE%\.claude-account-sync\backups` before changing anything. Personal stays the active account.

## Switching

Double-click **Switch to Personal** or **Switch to Org** on your Desktop. Then restart VS Code, Zed and any open terminals.

Claude Desktop keeps its own sign-in, so sign out and back in there if you want it on the same account.

From a terminal you can also run:

| Command | What it does |
|---|---|
| `claude-personal` | Start Claude Code as personal, whatever the active account is |
| `claude-org` | Start Claude Code as org, whatever the active account is |
| `claude-account switch org` | Same as the Desktop file |
| `claude-account status` | Show the active account and who is logged in |
| `claude-account sync` | Sync right now |

`claude-personal` and `claude-org` can run side by side in different terminals.

## Which account am I on?

The status line at the bottom of Claude Code shows `personal | you@example.com` or `org | you@company.com`. If you already had your own status line, it is left alone. Type `/status` in that case.

## Keeping a folder on one account

To make a project always open with one account regardless of the switch:

**VS Code**: add this to the folder's `.vscode/settings.json`:

```json
{
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "C:\\Users\\<you>\\.claude-org" }
  ]
}
```

**Zed**: add this to your Zed settings to fix the account for all projects:

```json
{
  "agent_servers": {
    "claude": {
      "env": { "CLAUDE_CONFIG_DIR": "C:\\Users\\<you>\\.claude-org" }
    }
  }
}
```

## How syncing works

Folders are linked with Windows junctions and files with hard links, so both accounts see the same data instantly. Claude Code sometimes rewrites a file instead of editing it, which breaks the hard link. A background task runs every 10 minutes and on every switch to fix this. It keeps the newest version, and any older version it replaces goes to `%USERPROFILE%\.claude-account-sync\conflicts` for 30 days.

`.claude.json` mixes account details with shared settings, so it is merged key by key instead of linked. Project settings, MCP servers, onboarding state and similar keys are shared. Login, account, organization and usage details stay per account.

Activity is logged to `%USERPROFILE%\.claude-account-sync\sync.log`.

## Uninstall

Close all Claude apps and double-click `uninstall.cmd`. Your data moves back into a normal `%USERPROFILE%\.claude` folder for the personal account. The org account keeps its own copy in `%USERPROFILE%\.claude-org`. Backups are not deleted.

## Good to know

- Chats and Projects on claude.ai and in the Claude Desktop chat are stored online under each account, so they can't be shared this way.
- If you resume a personal session while using the org account, that session's history is sent to Anthropic under the org account, and the reverse is also true.
- A file in the Claude folder that is itself a symbolic link to somewhere else is left alone.
- To delete a shared folder everywhere, delete it from `.claude-shared`. To delete a shared file, delete it from `.claude-shared` and from both account folders.

## Tests

The merge logic has tests that run in PowerShell 7 on any OS:

```
pwsh -File tests/merge-tests.ps1
```
