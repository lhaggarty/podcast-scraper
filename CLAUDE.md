# Project Rules

## Git Operations Protocol
- Do not attempt to call Skill(git), Skill(commit), or any non-shell Git handler.
- All Git operations must be executed via the bash/terminal tool.
- When asked to stage, commit, or push:
  1. Run: git status
  2. Confirm branch: git branch --show-current
  3. Execute standard shell commands: git add, git commit, git push
- Never fabricate tool calls for Git.
