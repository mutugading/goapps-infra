# Issue and Project Management

This repository uses one GitHub Project per repo, but the same workflow should be reused in future repos such as `goapps-backend`, `goapps-frontend`, and `goapps-shared-proto`.

## Recommended Project Structure

- One project per repository
- Same label taxonomy in every repo
- Same automation patterns across repos
- Separate boards for each repo, not one shared board

## Board Columns

Use a single status field with these values:

1. Backlog
2. Triage
3. Ready
4. In Progress
5. Review
6. Blocked
7. Done

## Suggested Views

| View | Filter |
|------|--------|
| All items | Everything in the project |
| Bugs | `type:bug` |
| Features | `type:feature` |
| Infrastructure | `area:infra OR area:services` |
| Docs | `type:docs` |
| High priority | `priority:p0 OR priority:p1` |
| Stale / needs attention | `stale OR status:triage OR status:blocked` |

## Label Taxonomy

| Label | Purpose |
|-------|---------|
| `type:bug` | Bug report or defect |
| `type:feature` | New feature or enhancement |
| `type:chore` | Maintenance work |
| `type:docs` | Documentation only |
| `type:incident` | Production incident |
| `area:infra` | Platform / infrastructure work |
| `area:services` | Service deployment work |
| `priority:p0` | Critical |
| `priority:p1` | High |
| `priority:p2` | Normal |
| `priority:p3` | Low |
| `status:triage` | New issue waiting for review |
| `status:blocked` | Work blocked by dependency |
| `status:needs-review` | Pull request waiting for review |
| `duplicate` | Confirmed duplicate issue |
| `stale` | Inactive issue needs attention |

## Automation

### Issue triage

- Adds new issues to the repo project when project variables are configured
- Applies `status:triage` to issues that do not already have a status label
- Comments with likely duplicate issue matches

### Pull request status

- Applies `status:needs-review` to active pull requests
- Moves draft pull requests to `status:in-progress`

### Stale management

- Marks inactive issues with `stale`
- Leaves high-priority and blocked issues untouched
- Uses a 21-day inactivity threshold and a 14-day close window after the stale warning

## Setup

1. Create a GitHub Project for the repository.
2. Add the status field values listed above.
3. Create the views listed above.
4. Set repository variables:
   - `GOAPPS_PROJECT_OWNER`
   - `GOAPPS_PROJECT_NUMBER`
5. Ensure GitHub Actions has `issues: write` and `projects: write`.

If you add more repositories later, copy the same automation and only change the project variables.
