# Contributing

You may propose new features or improvements by filing an issue. If you propose a new emulator, you will need to create the manifest file and complete the checklist provided in the template.

## Commit Message Guidelines (Conventional Commits)

This project follows [Conventional Commits](https://www.conventionalcommits.org/) specification for clear, semantic commit messages.

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Type
Must be one of:
- **feat**: A new feature or manifest addition
- **fix**: Bug fix or manifest repair
- **docs**: Documentation changes (README, guides, etc.)
- **refactor**: Code refactoring without feature changes
- **test**: Test script additions or updates
- **chore**: Build process, dependencies, or automation
- **ci**: CI/CD configuration changes
- **perf**: Performance improvements

### Scope
The scope should specify which part of the project:
- **bucket**: Changes to manifest files
- **scripts**: Changes to bin/ scripts (checkver, autofix, etc.)
- **ci**: GitHub Actions workflow changes
- **docs**: Documentation updates
- Optional for minor changes

### Subject
- Imperative mood ("add" not "added")
- No period at the end
- Maximum 50 characters
- Lowercase except for acronyms

### Body
- Explain *what* and *why*, not *how*
- Wrap at 72 characters
- Separate from subject with blank line
- Optional but recommended for non-trivial changes

### Footer
- Close related issues: `Closes #123`, `Fixes #456`
- Reference PRs: `PR #789`
- Optional but useful for automation

### Examples

```
feat(bucket): add RetroArch 1.22.1 manifest

Added new RetroArch emulator manifest with support for 32-bit and 64-bit
Windows installations. Includes proper autoupdate configuration pointing to
official GitHub releases.

Closes #456
```

```
fix(bucket): repair desmume manifest URL and hash

Replaced broken nightly.link URL with direct GitHub releases download.
Updated SHA256 hash to match new download location.

Fixes #789
```

```
refactor(scripts): improve checkver output parsing

Enhanced checkver wrapper to handle both outdated and current version
formats without subprocess overhead. Uses native PowerShell I/O redirection.
```

```
ci: add validation and auto-merge to Copilot workflow

Implements automated manifest validation after Copilot PR creation.
Runs checkver, autoupdate check, and installation test. Auto-merges
if all pass, requests fixes if any fail, escalates to @beyondmeat.
```

## Automated Validation & Merge Workflow

All PRs automatically run validation tests. See [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md) for detailed workflow documentation.

### Validation Requirements

**IMPORTANT:** All manifests must pass these validations:

```powershell
# Check for version detection
.\bin\checkver.ps1 -App <app-name> -Dir bucket

# Check for autoupdate configuration
.\bin\check-autoupdate.ps1 -ManifestPath bucket/<app-name>.json

# Check for installation
.\bin\check-manifest-install.ps1 -ManifestPath bucket/<app-name>.json
```

### Workflow Summary
- **User PR**: Validation runs → Tags @beyondmeat for review if all pass
- **Copilot PR**: Validation runs → Auto-merges if all pass, retries up to 10 times on failure
- **Complex Issues**: After 10 failed attempts, escalated to @beyondmeat for manual review

For complete details, see [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md#automated-pr-validation--auto-merge-workflow).

## Manifest Validation Requirements

Anytime a manifest is added or modified, it MUST be validated using the validation scripts. Validation is automatic in pull requests, but can be run locally for testing.

## Requirements for Adding a New Emulator

- Active development: Recent commit activity (past 2 years)
- Recent releases: Stable release within past 3 years
- Windows compatibility: Works on Windows 10 and Windows 11
- Portable mode: App data stored in same folder as app
- User base: Strong user base with broad appeal

If you answer NO to any of these, consider other buckets that may be a better fit.

## Creating a Manifest

A scoop [app manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) is a JSON file that tells Scoop how to install/update/uninstall an app. Read the [manifest documentation](https://github.com/ScoopInstaller/Scoop/wiki/Creating-an-app-manifest) before starting.

### Before You Start

1. **Research**: Can you create a complete, full-featured manifest?
2. **Maintenance**: Will you fix the manifest when upstream changes break it?

If yes to both, copy a similar manifest and customize it. If no, gather information and file an issue with the template.

## Pull Request Process

1. **Create Feature Branch**: Use conventional commit naming
2. **Make Changes**: Update manifests and/or scripts
3. **Validation**: Run validation scripts locally
4. **Commit Messages**: Follow Conventional Commits format
5. **Submit PR**: Include description and issue reference
6. **Automated Tests**: Wait for validation to complete
7. **Review**: Address any feedback or failed validations
8. **Merge**: Automatic if all validations pass, or manual if review needed

### PR Checklist

- [ ] Commit messages follow Conventional Commits format
- [ ] Validation scripts pass (checkver, autoupdate, install)
- [ ] Manifest is valid JSON
- [ ] PR description explains the change
- [ ] Closes/Fixes relevant issues
- [ ] No unrelated changes included

## Automated Validation Features

### GitHub Copilot Integration

The system automatically:
1. Attempts auto-fixes for broken manifests
2. Engages Copilot for complex issues (up to 10 fix attempts)
3. Auto-merges Copilot PRs when all validations pass
4. Escalates complex issues to @beyondmeat

For details, see [AUTOFIX_EXCAVATOR.md](./AUTOFIX_EXCAVATOR.md) and [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md).

