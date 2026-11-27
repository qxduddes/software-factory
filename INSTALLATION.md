INSTALLATION INSTRUCTION:

1. Installation & First Run

    Run the script in a dedicated factory directory (not inside the product repo).
    It skips files that already exist; pass --force to overwrite them:
    chmod +x setup-factory.sh && ./setup-factory.sh

2. Install and verify dependencies (jq, gitleaks, gh authenticated):

    brew install jq gitleaks
    which jq gh gitleaks && gh auth status

   The push hook blocks every push if gitleaks is missing.

3. Make sure the Jira workflow has the statuses `To Do`, `In Progress`, `Code Review`, `Done`.

4. Launch claude in the factory directory, run /mcp to authenticate atlassian via OAuth for your project's Jira site, and start the pipeline with the Jira URL and the product repo path:

    /factory https://your-project.atlassian.net/browse/PROJ-100 /path/to/product-repo

   Worktrees are created next to the repo, in /path/to/.worktrees/<TICKET-KEY>.
   You approve each ticket before its PR is opened; you merge and move the ticket to Done.
