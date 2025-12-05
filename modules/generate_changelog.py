import argparse
import re
import sys
import requests  # type: ignore
from typing import List, Dict, Optional, Any

# --- Formatted Output ---


def log_info(log_type: str, message: str) -> None:
    """Print formatted info message matching PowerShell output style."""
    print(f" >> {log_type}: {message}", file=sys.stderr)


def log_success(log_type: str, message: str) -> None:
    """Print formatted success message matching PowerShell output style."""
    print(f" ++ {log_type}: {message}", file=sys.stderr)


def log_warning(log_type: str, message: str) -> None:
    """Print formatted warning message matching PowerShell output style."""
    print(f" !! {log_type}: {message}", file=sys.stderr)


def log_error(log_type: str, message: str) -> None:
    """Print formatted error message matching PowerShell output style."""
    print(f" ** {log_type}: {message}", file=sys.stderr)


# --- GitHub API Interaction ---


def invoke_github_api(uri: str) -> Optional[Any]:
    """Invokes the GitHub API with a GET request."""
    try:
        headers = {"Accept": "application/vnd.github.v3+json"}
        # For private repos or higher rate limits, add:
        # headers["Authorization"] = "token YOUR_GITHUB_TOKEN"
        response = requests.get(uri, headers=headers, timeout=10)
        response.raise_for_status()  # Raises an exception for HTTP errors
        return response.json()
    except requests.exceptions.RequestException as e:
        log_warning("GitHub API", f"Request failed: {e}")
        return None


def get_github_release_body_lines(owner: str, repo: str, tag: str) -> List[str]:
    """Fetches the body of a GitHub release and returns it as a list of lines."""
    log_info("Fetching", f"Release '{tag}' from {owner}/{repo}")
    release_url = f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}"
    release_info = invoke_github_api(release_url)

    if not release_info:
        log_warning("Release", f"Could not fetch info for tag '{tag}'")
        return []

    body = release_info.get("body")
    if not body:
        log_warning("Release", f"Body for tag '{tag}' is empty")
        return []

    log_success("Fetched", f"Release '{tag}' ({len(body.splitlines())} lines)")
    return body.splitlines()

# --- Package Parsing Logic ---


def parse_package_line(line: str) -> Optional[Dict[str, Any]]:
    """Parses a single package line into its components."""
    trimmed_line = line.strip()
    match = re.match(
        r"^\s*-\s*(.+?)\s+([\d.a-zA-Z]+(?:-[\w.]+)?(?:-\w+)?)\s*(\(.*\))?\s*$", trimmed_line)
    if match:
        return {
            "name": match.group(1).strip(),
            "version": match.group(2).strip(),
            "extra_info": match.group(3).strip() if match.group(3) else "",
            "full_line": trimmed_line
        }
    match = re.match(r"^\s*-\s*(.+?)\s*$", trimmed_line)
    if match:
        return {
            "name": match.group(1).strip(),
            "version": None,
            "extra_info": "",
            "full_line": trimmed_line
        }
    return None


def get_packages_dict(lines_list: List[str]) -> Dict[str, Dict[str, Any]]:
    """Converts a list of package lines into a dictionary keyed by package name."""
    packages: Dict[str, Dict[str, Any]] = {}
    for line in lines_list:
        parsed_package = parse_package_line(line)
        if parsed_package and parsed_package["name"]:
            packages[parsed_package["name"]] = parsed_package
    return packages


def get_packages_from_markdown_lines(markdown_lines: List[str]) -> Dict[str, Dict[str, Any]]:
    """Extracts and parses package list from Markdown lines (e.g., GitHub release body)."""
    package_lines_for_parsing: List[str] = []
    in_package_info_section = False
    in_package_list = False
    if not markdown_lines:
        # print("Warning: No lines provided to get_packages_from_markdown_lines.") # Less verbose
        return {}
    for line in markdown_lines:
        if re.match(r"^##\s*Package Info", line, re.IGNORECASE):
            in_package_info_section = True
            continue
        if in_package_info_section and "This is the winlibs Intel/AMD" in line and "build of:" in line:
            in_package_list = True
            continue
        if in_package_info_section and in_package_list:
            if line.strip().startswith("- "):
                package_lines_for_parsing.append(line)
            elif re.match(r"^\s*##", line) or (not line.strip() and package_lines_for_parsing):
                if re.match(r"^\s*##", line):
                    break
    if not package_lines_for_parsing and in_package_info_section:
        log_warning(
            "Packages", "Found 'Package Info' section but no items extracted")
    return get_packages_dict(package_lines_for_parsing)


def main():
    parser = argparse.ArgumentParser(
        description="Generate changelog Markdown from package info.")
    parser.add_argument("--input-file",
                        help="Path to the text file with CURRENT build's package info. Required unless --current-tag is provided.")
    parser.add_argument("--output-file", required=True,
                        help="Path to write the generated Markdown output.")
    parser.add_argument("--prev-tag",
                        help="Previous GitHub release tag of this project (e.g., '2025.04.27'). Optional - if not provided, no package comparison will be made.")
    parser.add_argument("--current-build-tag", required=True,
                        help="Tag for the new release being built (e.g., '2025.06.09').")
    parser.add_argument("--current-tag",
                        help="If provided, fetch CURRENT package info from this GitHub release tag instead of reading from --input-file. Useful for comparing two existing releases.")
    parser.add_argument("--github-owner", default="ehsan18t",
                        help="GitHub repository owner.")
    parser.add_argument(
        "--github-repo", default="easy-mingw-installer", help="GitHub repository name.")
    args = parser.parse_args()

    # Validate: either --input-file or --current-tag must be provided
    if not args.input_file and not args.current_tag:
        parser.error("Either --input-file or --current-tag must be provided.")
    if args.input_file and args.current_tag:
        print("Note: Both --input-file and --current-tag provided. Using --current-tag (fetching from GitHub).")

    markdown_output: List[str] = []

    # --- Stage 1 & 2: Parse current package info (from GitHub or local file) ---
    current_package_lines_for_info_section: List[str] = []

    if args.current_tag:
        # Fetch current package info from GitHub release
        log_info(
            "Mode", f"Fetching current package info from GitHub tag '{args.current_tag}'")
        current_release_body_lines = get_github_release_body_lines(
            args.github_owner, args.github_repo, args.current_tag)

        if not current_release_body_lines:
            log_error(
                "Release", f"Could not fetch body for current tag '{args.current_tag}'")
            sys.exit(1)

        # Parse the release body to build markdown output and extract package lines
        in_package_info = False
        in_package_list = False
        for line in current_release_body_lines:
            line_strip = line.strip()

            # Look for Package Info section header
            if re.match(r"^##\s*Package Info", line, re.IGNORECASE):
                markdown_output.append("## Package Info")
                in_package_info = True
                continue

            # Look for the winlibs description line
            if in_package_info and "This is the winlibs Intel/AMD" in line and "build of:" in line:
                markdown_output.append(
                    "This is the winlibs Intel/AMD 64-bit & 32-bit standalone build of:")
                in_package_list = True
                continue

            if in_package_list:
                if line_strip.startswith("- "):
                    current_package_lines_for_info_section.append(line_strip)
                    markdown_output.append(line_strip)
                elif re.match(r"^\s*##", line):  # Next section
                    in_package_list = False
                    in_package_info = False
                    markdown_output.append("")
                elif not line_strip and current_package_lines_for_info_section:
                    # Empty line after packages - end of list
                    pass

            # Extract thread model, runtime, build date from current release
            if not in_package_list and in_package_info:
                if "<strong>Thread model:</strong>" in line:
                    markdown_output.append(line_strip)
                    markdown_output.append("")
                    markdown_output.append("<br>")
                    markdown_output.append("")
                elif "<strong>Runtime library:</strong>" in line:
                    markdown_output.append(line_strip)
                    markdown_output.append("")
                elif line_strip.startswith(">") and "compiled with GCC" in line:
                    markdown_output.append(line_strip)
                    markdown_output.append("")

        if not current_package_lines_for_info_section:
            log_warning(
                "Packages", f"No package list found in release '{args.current_tag}'")
        else:
            log_info(
                "Packages", f"Found {len(current_package_lines_for_info_section)} in current release")

    else:
        # Read from local input file
        try:
            with open(args.input_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
        except FileNotFoundError:
            log_error("Input File", f"Not found: {args.input_file}")
            sys.exit(1)

        in_package_list_section = False

        for line_content in lines:
            line_strip = line_content.strip()

            if not in_package_list_section and "This is the winlibs Intel/AMD" in line_content and "build of:" in line_content:
                markdown_output.append("## Package Info")
                markdown_output.append(
                    "This is the winlibs Intel/AMD 64-bit & 32-bit standalone build of:")
                in_package_list_section = True
                continue

            if in_package_list_section:
                if line_strip.startswith("- "):
                    current_package_lines_for_info_section.append(line_strip)
                    markdown_output.append(line_strip)
                elif not line_strip:
                    pass
                elif line_strip.startswith("Thread model:") or \
                        line_strip.startswith("Runtime library:") or \
                        ("This build was compiled with GCC" in line_content and "and packaged on" in line_content):
                    in_package_list_section = False
                    markdown_output.append("")
                elif markdown_output and markdown_output[-1].startswith("- "):
                    in_package_list_section = False
                    markdown_output.append("")

            if not in_package_list_section:
                if line_strip.startswith("Thread model:"):
                    thread_model_value = line_strip.split(":", 1)[1].strip()
                    if thread_model_value.lower() == "posix":
                        thread_model_value = "POSIX"
                    markdown_output.append(
                        f"<strong>Thread model:</strong> {thread_model_value}")
                    markdown_output.append("")
                    markdown_output.append("<br>")
                    markdown_output.append("")
                elif line_strip.startswith("Runtime library:"):
                    runtime_library_value = line_strip.split(":", 1)[1].strip()
                    markdown_output.append(
                        f"<strong>Runtime library:</strong> {runtime_library_value}<br>")
                    markdown_output.append("")
                elif "This build was compiled with GCC" in line_content and "and packaged on" in line_content:
                    full_build_line_text = line_strip.replace(
                        ".", "", 1) if line_strip.endswith(".") else line_strip
                    markdown_output.append(f"> {full_build_line_text}")
                    markdown_output.append("")

    if not current_package_lines_for_info_section and "## Package Info" in markdown_output:
        log_warning("Packages", "Could not parse package list from input file")
        if markdown_output and markdown_output[-1] != "":
            markdown_output.append("")

    # --- Stage 4: Static Script Changelog ---
    markdown_output.append("## Script/Installer Changelogs")
    markdown_output.append("* None")
    markdown_output.append("")

    # --- Stage 5: Package Changelogs ---
    markdown_output.append("## Package Changelogs")

    previous_packages_dict: Dict[str, Dict[str, Any]] = {}
    previous_release_body_lines: List[str] = []

    if args.prev_tag:
        previous_release_body_lines = get_github_release_body_lines(
            args.github_owner, args.github_repo, args.prev_tag)
        previous_packages_dict = get_packages_from_markdown_lines(
            previous_release_body_lines)
    else:
        log_info("Changelog", "No previous tag provided - skipping comparison")

    current_packages_dict = get_packages_dict(
        current_package_lines_for_info_section)

    updated_package_strings: List[str] = []
    added_package_strings: List[str] = []
    removed_package_strings: List[str] = []

    for name, c_pkg in current_packages_dict.items():
        if name in previous_packages_dict:
            p_pkg = previous_packages_dict[name]
            if c_pkg["version"] != p_pkg["version"]:
                package_name = c_pkg['name']
                old_version_display = p_pkg["version"] if p_pkg["version"] else "N/A"
                new_version_display = c_pkg["version"] if c_pkg["version"] else "N/A"
                extra_info_display = f" {c_pkg['extra_info']}" if c_pkg['extra_info'] else ""
                updated_line = f"- {package_name} ({old_version_display} -> {new_version_display}){extra_info_display}"
                updated_package_strings.append(updated_line)
        else:
            added_package_strings.append(f"{c_pkg['full_line']} (added)")

    for name, p_pkg in previous_packages_dict.items():
        if name not in current_packages_dict:
            removed_package_strings.append(f"{p_pkg['full_line']} (removed)")

    all_changes: List[str] = []
    all_changes.extend(updated_package_strings)
    all_changes.extend(added_package_strings)
    all_changes.extend(removed_package_strings)

    if all_changes:
        markdown_output.extend(all_changes)
    else:
        if not args.prev_tag:
            markdown_output.append(
                "* No previous version to compare against.")
        elif previous_release_body_lines and previous_packages_dict:
            markdown_output.append(
                f"* No package changes detected compared to the previous version (`{args.prev_tag}`).")
        elif previous_release_body_lines and not previous_packages_dict:
            markdown_output.append(
                f"* Previous release body for tag `'{args.prev_tag}'` was found but no package list could be parsed.")
        else:
            markdown_output.append(
                "* Could not retrieve previous version's package list.")
        if not current_packages_dict and not all_changes:
            markdown_output.append("* No current packages found to list.")
    markdown_output.append("")

    # --- Stage 6: Full Changelog Link ---
    markdown_output.append("<br>")
    markdown_output.append("")
    # Use args.current_build_tag for the end part of the compare URL
    if args.current_build_tag and args.prev_tag:
        markdown_output.append(
            f"**Full Changelog**: https://github.com/{args.github_owner}/{args.github_repo}/compare/{args.prev_tag}...{args.current_build_tag}")
    else:
        error_msg = "**Full Changelog**: [TODO: Update link"
        if not args.prev_tag:
            error_msg += " - Previous project tag missing"
        if not args.current_build_tag:
            error_msg += " - Current build tag missing"
        error_msg += "]"
        markdown_output.append(error_msg)
        log_warning("Changelog", "Full changelog link is incomplete")

    markdown_output.append("")
    markdown_output.append("<br>")
    markdown_output.append("")
    markdown_output.append("### File Hash")

    try:
        with open(args.output_file, 'w', encoding='utf-8') as f:
            f.write("\n".join(markdown_output))
        # Success message is printed by PowerShell caller
    except IOError as e:
        log_error("Write Failed", str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
