"""
Generate changelog Markdown from package info.

This script compares package versions between releases and generates a changelog
in Markdown format suitable for GitHub releases.
"""

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass
from typing import List, Dict, Optional, Any

import requests  # type: ignore

# =============================================================================
# Constants
# =============================================================================

# Regex patterns
PACKAGE_INFO_HEADER_PATTERN = r"^##\s*Package Info"
PACKAGE_LINE_PATTERN = r"^\s*-\s*(.+?)\s+([\d.a-zA-Z]+(?:-[\w.]+)?(?:-\w+)?)\s*(\(.*\))?\s*$"
PACKAGE_LINE_NO_VERSION_PATTERN = r"^\s*-\s*(.+?)\s*$"
SECTION_HEADER_PATTERN = r"^\s*##"

# String markers
WINLIBS_PREFIX = "This is the winlibs Intel/AMD"
WINLIBS_SUFFIX = "build of:"
WINLIBS_FULL_LINE = "This is the winlibs Intel/AMD 64-bit & 32-bit standalone build of:"

# API settings
GITHUB_API_BASE = "https://api.github.com"
GITHUB_API_TIMEOUT = 10
GITHUB_RETRY_COUNT = 3
GITHUB_RETRY_DELAY = 1.0

# Environment variables
ENV_GITHUB_TOKEN = "GITHUB_TOKEN"


# =============================================================================
# Logging Functions
# =============================================================================

# Log level prefixes matching PowerShell output style (see modules/pretty.ps1,
# $script:LogStyles). Keep these in sync: build logs interleave both scripts.
_LOG_PREFIXES = {
    "info": " [>] ",
    "success": " [+] ",
    "warning": " [!] ",
    "error": " [X] ",
}


def _log(level: str, log_type: str, message: str) -> None:
    """Print formatted message matching PowerShell output style."""
    prefix = _LOG_PREFIXES.get(level, " >> ")
    print(f"{prefix}{log_type}: {message}", file=sys.stderr)


def log_info(log_type: str, message: str) -> None:
    _log("info", log_type, message)


def log_success(log_type: str, message: str) -> None:
    _log("success", log_type, message)


def log_warning(log_type: str, message: str) -> None:
    _log("warning", log_type, message)


def log_error(log_type: str, message: str) -> None:
    _log("error", log_type, message)


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class Package:
    """Represents a parsed package with version info."""
    name: str
    version: Optional[str]
    extra_info: str
    full_line: str


# =============================================================================
# GitHub Client
# =============================================================================

class GitHubClient:
    """Handles GitHub API interactions with authentication and retry logic."""

    def __init__(self) -> None:
        self._token = os.environ.get(ENV_GITHUB_TOKEN)
        self._cache: Dict[str, Any] = {}

    def _get_headers(self) -> Dict[str, str]:
        """Build request headers with optional authentication."""
        headers = {"Accept": "application/vnd.github.v3+json"}
        if self._token:
            headers["Authorization"] = f"token {self._token}"
        return headers

    def invoke_api(self, uri: str) -> Optional[Any]:
        """
        Invoke the GitHub API with retry logic.

        Args:
            uri: The full API URL to call.

        Returns:
            Parsed JSON response or None on failure.
        """
        # Check cache first
        if uri in self._cache:
            return self._cache[uri]

        headers = self._get_headers()
        last_error: Optional[Exception] = None

        for attempt in range(GITHUB_RETRY_COUNT):
            try:
                response = requests.get(
                    uri, headers=headers, timeout=GITHUB_API_TIMEOUT)
                response.raise_for_status()
                result = response.json()
                self._cache[uri] = result
                return result
            except requests.exceptions.RequestException as e:
                last_error = e
                if attempt < GITHUB_RETRY_COUNT - 1:
                    time.sleep(GITHUB_RETRY_DELAY)
                    continue
                break

        log_warning(
            "GitHub API", f"Request failed after {GITHUB_RETRY_COUNT} attempts: {last_error}")
        return None

    def get_release_body_lines(self, owner: str, repo: str, tag: str) -> List[str]:
        """
        Fetch the body of a GitHub release as lines.

        Args:
            owner: Repository owner.
            repo: Repository name.
            tag: Release tag name.

        Returns:
            List of body lines, or empty list on failure.
        """
        log_info("Fetching", f"Release '{tag}' from {owner}/{repo}")
        release_url = f"{GITHUB_API_BASE}/repos/{owner}/{repo}/releases/tags/{tag}"
        release_info = self.invoke_api(release_url)

        if not release_info:
            log_warning("Release", f"Could not fetch info for tag '{tag}'")
            return []

        body = release_info.get("body")
        if not body:
            log_warning("Release", f"Body for tag '{tag}' is empty")
            return []

        log_success(
            "Fetched", f"Release '{tag}' ({len(body.splitlines())} lines)")
        return body.splitlines()


# =============================================================================
# Package Parser
# =============================================================================

@dataclass
class BuildInfo:
    """Everything parsed out of a version_info.txt or a release body."""
    package_lines: List[str]      # raw "- name version" lines, in order
    thread_model: str
    runtime_library: str
    build_line: str               # "This build was compiled with GCC ... packaged on ..."


# Markdown decorations that wrap the same content as plain text:
#   <strong>Thread model:</strong> POSIX   ->   Thread model: POSIX
#   > This build was compiled with GCC ... ->   This build was compiled with GCC ...
#   <br>                                   ->   (empty)
_MARKDOWN_NOISE = re.compile(r"</?strong>|^>\s*|<br>\s*$")


def normalize(line: str) -> str:
    """Strip markdown decoration so one parser handles both input formats."""
    return _MARKDOWN_NOISE.sub("", line.strip()).strip()


def parse_build_info(lines: List[str]) -> BuildInfo:
    """
    Parse package info from either a version_info.txt or a GitHub release body.

    Both formats carry the same content; markdown just decorates it. normalize()
    removes the decoration, so the state machine below is format-agnostic. This
    replaced three near-duplicate parsers that had to be kept in step by hand.

    The package list starts at the winlibs header line (one containing both
    WINLIBS_PREFIX and WINLIBS_SUFFIX) and ends at the first non-"- " line.
    """
    packages: List[str] = []
    thread_model = ""
    runtime_library = ""
    build_line = ""
    in_list = False

    for raw in lines:
        line = normalize(raw)

        if not in_list:
            if WINLIBS_PREFIX in line and WINLIBS_SUFFIX in line:
                in_list = True
                continue
        else:
            if line.startswith("- "):
                packages.append(line)
                continue
            if line:
                in_list = False   # fall through and classify this line below

        if line.startswith("Thread model:"):
            thread_model = line.split(":", 1)[1].strip()
            if thread_model.lower() == "posix":
                thread_model = "POSIX"
        elif line.startswith("Runtime library:"):
            runtime_library = line.split(":", 1)[1].strip()
        elif "This build was compiled with GCC" in line and "and packaged on" in line:
            build_line = line.rstrip(".")

    return BuildInfo(packages, thread_model, runtime_library, build_line)


def parse_package_line(line: str) -> Optional[Package]:
    """
    Parse "- GCC 14.2.0 (with POSIX threads)" into a Package.

    Falls back to a name-only Package for lines with no version, such as "- ccache".
    """
    trimmed = line.strip()

    match = re.match(PACKAGE_LINE_PATTERN, trimmed)
    if match:
        return Package(
            name=match.group(1).strip(),
            version=match.group(2).strip(),
            extra_info=match.group(3).strip() if match.group(3) else "",
            full_line=trimmed,
        )

    match = re.match(PACKAGE_LINE_NO_VERSION_PATTERN, trimmed)
    if match:
        return Package(name=match.group(1).strip(), version=None,
                       extra_info="", full_line=trimmed)

    return None


def packages_to_dict(lines: List[str]) -> Dict[str, Package]:
    """Convert raw package lines to a dict keyed by package name."""
    packages: Dict[str, Package] = {}
    for line in lines:
        pkg = parse_package_line(line)
        if pkg and pkg.name:
            packages[pkg.name] = pkg
    return packages

# =============================================================================
# Changelog Generator
# =============================================================================

class ChangelogGenerator:
    """Generates changelog markdown by comparing package versions."""

    def __init__(self, github_client: GitHubClient, owner: str, repo: str) -> None:
        self.client = github_client
        self.owner = owner
        self.repo = repo
        self.markdown_output: List[str] = []
        self.current_package_lines: List[str] = []

    def _append(self, *lines: str) -> None:
        """Append one or more lines to markdown output."""
        self.markdown_output.extend(lines)

    def _render_package_info(self, info: BuildInfo) -> None:
        """Emit the Package Info section from parsed build info."""
        if info.package_lines:
            self._append("## Package Info", WINLIBS_FULL_LINE)
            self._append(*info.package_lines)
            self._append("")
        else:
            log_warning("Packages", "No package list found in input")

        if info.thread_model:
            self._append(f"<strong>Thread model:</strong> {info.thread_model}", "", "<br>", "")
        if info.runtime_library:
            self._append(f"<strong>Runtime library:</strong> {info.runtime_library}<br>", "")
        if info.build_line:
            self._append(f"> {info.build_line}", "")

    def _add_script_changelog(self) -> None:
        """Add the static script/installer changelog section."""
        self._append("## Script/Installer Changelogs", "* None", "")

    def _compare_packages(self, prev_tag: Optional[str]) -> None:
        """Compare current and previous packages to generate changelog."""
        self._append("## Package Changelogs")

        previous_packages: Dict[str, Package] = {}
        previous_body_lines: List[str] = []

        if prev_tag:
            previous_body_lines = self.client.get_release_body_lines(
                self.owner, self.repo, prev_tag)
            previous_packages = packages_to_dict(
                parse_build_info(previous_body_lines).package_lines)
        else:
            log_info("Changelog", "No previous tag provided - skipping comparison")

        current_packages = packages_to_dict(self.current_package_lines)

        updated: List[str] = []
        added: List[str] = []
        removed: List[str] = []

        # Find updated and added packages
        for name, c_pkg in current_packages.items():
            if name in previous_packages:
                p_pkg = previous_packages[name]
                if c_pkg.version != p_pkg.version:
                    old_ver = p_pkg.version or "N/A"
                    new_ver = c_pkg.version or "N/A"
                    extra = f" {c_pkg.extra_info}" if c_pkg.extra_info else ""
                    updated.append(
                        f"- {c_pkg.name} ({old_ver} -> {new_ver}){extra}")
            else:
                added.append(f"{c_pkg.full_line} (added)")

        # Find removed packages
        for name, p_pkg in previous_packages.items():
            if name not in current_packages:
                removed.append(f"{p_pkg.full_line} (removed)")

        all_changes = updated + added + removed

        if all_changes:
            self.markdown_output.extend(all_changes)
        else:
            self._add_no_changes_message(
                prev_tag, previous_body_lines, previous_packages, current_packages)

        self._append("")

    def _add_no_changes_message(
        self,
        prev_tag: Optional[str],
        prev_body_lines: List[str],
        prev_packages: Dict[str, Package],
        current_packages: Dict[str, Package]
    ) -> None:
        """Add appropriate message when no package changes detected."""
        if not prev_tag:
            self._append("* No previous version to compare against.")
        elif prev_body_lines and prev_packages:
            self._append(f"* No package changes detected compared to the previous version (`{prev_tag}`).")
        elif prev_body_lines and not prev_packages:
            self._append(f"* Previous release body for tag `'{prev_tag}'` was found but no package list could be parsed.")
        else:
            self._append("* Could not retrieve previous version's package list.")

        if not current_packages:
            self._append("* No current packages found to list.")

    def _add_full_changelog_link(self, current_build_tag: str, prev_tag: Optional[str]) -> None:
        """Add the full changelog link section."""
        self._append("<br>", "")

        if current_build_tag and prev_tag:
            url = f"https://github.com/{self.owner}/{self.repo}/compare/{prev_tag}...{current_build_tag}"
            self._append(f"**Full Changelog**: {url}")
        else:
            parts = ["**Full Changelog**: [TODO: Update link"]
            if not prev_tag:
                parts.append(" - Previous project tag missing")
            if not current_build_tag:
                parts.append(" - Current build tag missing")
            parts.append("]")
            self._append("".join(parts))
            log_warning("Changelog", "Full changelog link is incomplete")

        self._append("", "<br>", "", "### File Hash")

    def generate(
        self,
        input_file: Optional[str],
        current_tag: Optional[str],
        prev_tag: Optional[str],
        current_build_tag: str,
        output_file: str
    ) -> bool:
        """
        Generate the full changelog and write to file.

        Current package info comes from current_tag (a GitHub release body) when
        given, otherwise from input_file (a local version_info.txt). Both are parsed
        by the same parse_build_info().

        Args:
            input_file: Path to local package info file (optional if current_tag provided).
            current_tag: GitHub tag to fetch current packages from (optional if input_file provided).
            prev_tag: GitHub tag for previous release (optional).
            current_build_tag: Tag for the new release being built.
            output_file: Path to write the generated markdown.

        Returns:
            True if successful, False otherwise.
        """
        if current_tag:
            log_info("Mode", f"Fetching current package info from GitHub tag '{current_tag}'")
            lines = self.client.get_release_body_lines(self.owner, self.repo, current_tag)
            if not lines:
                log_error("Release", f"Could not fetch body for current tag '{current_tag}'")
                return False
        else:
            try:
                with open(input_file, 'r', encoding='utf-8') as f:   # type: ignore
                    lines = f.readlines()
            except FileNotFoundError:
                log_error("Input File", f"Not found: {input_file}")
                return False

        info = parse_build_info(lines)
        self.current_package_lines = info.package_lines
        log_info("Packages", f"Found {len(info.package_lines)} in current release")

        self._render_package_info(info)
        self._add_script_changelog()
        self._compare_packages(prev_tag)
        self._add_full_changelog_link(current_build_tag, prev_tag)

        # Write output
        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write("\n".join(self.markdown_output))
            return True
        except IOError as e:
            log_error("Write Failed", str(e))
            return False


# =============================================================================
# Main Entry Point
# =============================================================================

def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Generate changelog Markdown from package info.")
    parser.add_argument(
        "--input-file",
        help="Path to the text file with CURRENT build's package info. "
             "Required unless --current-tag is provided.")
    parser.add_argument(
        "--output-file",
        required=True,
        help="Path to write the generated Markdown output.")
    parser.add_argument(
        "--prev-tag",
        help="Previous GitHub release tag of this project (e.g., '2025.04.27'). "
             "Optional - if not provided, no package comparison will be made.")
    parser.add_argument(
        "--current-build-tag",
        required=True,
        help="Tag for the new release being built (e.g., '2025.06.09').")
    parser.add_argument(
        "--current-tag",
        help="If provided, fetch CURRENT package info from this GitHub release tag "
             "instead of reading from --input-file. Useful for comparing two existing releases.")
    parser.add_argument(
        "--github-owner",
        default="ehsan18t",
        help="GitHub repository owner.")
    parser.add_argument(
        "--github-repo",
        default="easy-mingw-installer",
        help="GitHub repository name.")
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> bool:
    """Validate command line arguments."""
    if not args.input_file and not args.current_tag:
        log_error(
            "Arguments", "Either --input-file or --current-tag must be provided.")
        return False

    if args.input_file and args.current_tag:
        log_info(
            "Note", "Both --input-file and --current-tag provided. Using --current-tag (fetching from GitHub).")

    return True


def main() -> None:
    """Main entry point."""
    args = parse_args()

    if not validate_args(args):
        sys.exit(1)

    # Create GitHub client (uses GITHUB_TOKEN env var if available)
    client = GitHubClient()

    # Generate changelog
    generator = ChangelogGenerator(client, args.github_owner, args.github_repo)
    success = generator.generate(
        input_file=args.input_file,
        current_tag=args.current_tag,
        prev_tag=args.prev_tag,
        current_build_tag=args.current_build_tag,
        output_file=args.output_file
    )

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
