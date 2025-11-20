# Excavator Auto-Fix Enhancement

## Overview

The Excavator GitHub workflow automatically detects and fixes common manifest issues during hourly version checks. The system uses a multi-tier approach:
1. **Auto-fix attempts** for common URL and hash issues
2. **Copilot integration** for complex problems (up to 10 fix attempts)
3. **Escalation to maintainers** for issues beyond automation

For detailed workflow documentation, see [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md).

## Quick Reference

### Workflow Steps
1. **Excavate**: Check for new releases (hourly via GitHub Actions)
2. **Auto-fix**: Attempt to fix broken manifests automatically
3. **Copilot PR**: Request AI-assisted fixes if auto-fix fails
4. **Validate**: Run validation tests (checkver, autoupdate, install)
5. **Merge**: Auto-merge on success or escalate on failure

### Exit Outcomes
- ✅ **Fixed & Merged**: Copilot PR auto-merged after validation passes
- ⏳ **Under Review**: Complex issues escalated to @beyondmeat
- ❌ **Failed**: After 10 attempts, escalated to manual review

## Capabilities

The auto-fix system can repair:
- **URL issues**: Simple version substitution and GitHub API lookups
- **Hash errors**: SHA256 recalculation for updated downloads
- **Checkver fixes**: Intelligent regex pattern suggestions
- **Multi-platform**: GitHub, GitLab, Gitea repository support
- **Structure validation**: Detects manifest format issues

See [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md#intelligent-manifest-repair) for detailed feature documentation.

## Script Reference

For detailed script documentation and parameters, see [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md#intelligent-manifest-repair).

## Benefits

1. **Automated Recovery**: Manifests automatically fixed when upstream changes occur
2. **Zero Maintenance**: Common URL/version issues resolved without manual intervention
3. **Speed**: Broken manifests fixed and deployed within the hour
4. **Transparency**: Full audit trail in git history

## Getting Help

- **Implementation details**: See [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md)
- **Contributing**: See [CONTRIBUTING.md](./CONTRIBUTING.md)
- **Script errors**: Check GitHub Actions logs in `.github/workflows/excavator.yml`
