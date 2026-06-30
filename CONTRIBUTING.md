# Contributing to Scoop Emulators

Thank you for your interest in contributing! You may propose new features, fix broken manifests, or request new emulators. This guide explains how the bucket operates and the workflows for submitting changes.

---

## 1. For Users: Requesting an Emulator

If you are not comfortable writing code or JSON manifests, you can simply request an emulator and our automated systems will attempt to build and add it for you.

1. Go to the [Issues page](https://github.com/borger/scoop-emulators/issues).
2. Click **New Issue**.
3. Use the following format in your issue:

   ```text
   Title: Add [Emulator Name]

   Body:
   Please add support for [Emulator Name]
   GitHub: https://github.com/owner/repo
   ```

4. Add the label: `request-manifest` or `emulator-request`.
5. Click **Submit new issue**.

**What happens next?**
The system will automatically detect the GitHub URL, run a manifest creation script to download and test the emulator, and if successful, generate the JSON manifest and add it to the bucket automatically.

---

## 2. Requirements for New Emulators

If you are adding an emulator manually, ensure it meets the following criteria:

- **Active development**: Recent commit activity within the past 6 months.
- **Recent releases**: Stable release within the past year.
- **Windows compatibility**: Works natively on Windows 10 and Windows 11.
- **Portable mode**: Application data must be stored in the same folder as the app (this is enforced via `portable.txt` or start scripts in the manifest).
- **User base**: Strong user base with broad appeal.

If your proposed emulator fails these checks, consider adding it to your personal bucket or a more general bucket.

---

## 3. For Developers: Creating a Manifest Manually

A Scoop [app manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) is a JSON file that tells Scoop how to install, update, and uninstall an app.

### Using the Automated Script

Instead of writing the manifest entirely from scratch, use our built-in scaffolding tool:

```powershell
# Navigate to the bucket directory
cd %USERPROFILE%\scoop\buckets\emulators

# Create manifest from a GitHub URL
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/emulator/repo"
```

**What the script does:**

1. Downloads the latest release and extracts executables.
2. Monitors the file system to detect where the app creates its data (e.g., AppData, Documents).
3. Generates a complete `bucket/[app-name].json` manifest.
4. Auto-configures `portable_data`, `checkver`, and `autoupdate` blocks.

### Manifest Feature Explanations

When reviewing the generated manifest, note the following configurations:

- **`post_install` / `pre_install`**: Often used to create a `portable.txt` file or migrate data from AppData to enforce portable mode.
- **`persist`**: Lists the folders where game data/saves are stored so they are retained across app updates.
- **`shortcuts`**: Formatted with platform-specific names (e.g. `["app.exe", "Nintendo 64 [n64][g64]"]`).

---

## 4. Validating Manifests

**All manifests MUST pass our local test suite before being submitted as a PR.** Validation runs automatically in CI, but you should run it locally first to save time.

Run the following three tests in PowerShell:

```powershell
cd %USERPROFILE%\scoop\buckets\emulators

# 1. Test version detection (checkver)
.\bin\checkver.ps1 -Dir bucket -App <app-name>

# 2. Test urls
.\bin\checkurls.ps1 -Dir bucket -App <app-name>

# 3. Validate autoupdate configuration
.\bin\check-autoupdate.ps1 -ManifestPath bucket\<app-name>.json

# 4. Test actual installation
.\bin\check-manifest-install.ps1 -ManifestPath bucket\<app-name>.json
```

Checkver should output the latest release version.
All commands must output `[OK]` or `[SUCCESS]`.

### Troubleshooting Validation Failures

- **"No suitable Windows executable found"**: The GitHub repo may not have a Windows binary, or it uses an unrecognized naming convention.
- **404 during Autoupdate**: Ensure your `$version` placeholder in the autoupdate URL exactly matches the format emitted by `checkver`.
- **Application crashes during install test**: Review the manifest structure and run the installation manually (`scoop install .\bucket\<app-name>.json`) to see what fails.

---

## 5. Pull Request Process & Guidelines

1. **Create a Feature Branch**: Use conventional commit naming (see below).
2. **Make Changes**: Update manifests or scripts.
3. **Run Validation**: Ensure all three tests (above) pass.
4. **Submit PR**: Include a description and reference any related issues.
5. **Review**: The CI will run tests automatically.
6. **Merge**: If all checks pass, your PR may be auto-merged by the system!

### Commit Message Format (Conventional Commits)

We strictly follow [Conventional Commits](https://www.conventionalcommits.org/).

**Format:**

```text
<type>(<scope>): <subject>
```

**Allowed Types:**

- `feat`: A new feature or new manifest addition.
- `fix`: Bug fix or manifest repair.
- `docs`: Documentation changes.
- `refactor`: Code refactoring.
- `test`: Test scripts.
- `chore`: Automation, CI, or dependency updates.

**Allowed Scopes:**

- `bucket`: Changes to manifest files.
- `scripts`: Changes to the internal `bin/` scripts.
- `docs`: Documentation updates.
- `ci`: GitHub Actions.

**Example:**

```text
feat(bucket): add RetroArch 1.22.1 manifest
fix(bucket): repair desmume manifest URL and hash
```

---

## 6. CI/CD & Automation Workflows

This bucket uses heavily customized automated workflows to maintain emulators.

- **Excavator (`excavator.yml`)**: Runs hourly. Uses Scoop's official action to scan for new versions of all emulators and creates automated PRs.
- **Auto-Fix (`auto-fix.yml`)**: If a manifest breaks (e.g. the developer changes their URL structure or naming convention), this workflow automatically attempts to repair the manifest by detecting the new scheme and pushing a fix.
- **Copilot Integration**: For complex manifest breakages, the system will engage an AI agent to attempt to write a fix (up to 10 attempts). If it passes validation, it auto-merges. If it fails, it escalates to a human maintainer.
- **PR Validation (`pull_request.yml`)**: Automatically runs the three validation scripts on all incoming pull requests.

For technical maintainers looking for deep-dives into how the `bin/` scripts and automation engine works under the hood, see [DEVELOPMENT.md](./DEVELOPMENT.md).
