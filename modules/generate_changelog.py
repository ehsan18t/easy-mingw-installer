import argparse
import re
import requests  # type: ignore
from typing import List, Dict, Optional, Any

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
        print(f"Warning: Failed to invoke GitHub API: {e} for URI: {uri}")
        return None


def get_github_release_body_lines(owner: str, repo: str, tag: str) -> List[str]:
    """Fetches the body of a GitHub release and returns it as a list of lines."""
    print(
        f"Fetching release information for tag '{tag}' from '{owner}/{repo}'...")
    release_url = f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}"
    release_info = invoke_github_api(release_url)

    if not release_info:
        print(f"Warning: Could not fetch release info for tag '{tag}'.")
        return []

    body = release_info.get("body")
    if not body:
        print(f"Warning: Release body for tag '{tag}' is empty or not found.")
        return []

    print(f"Successfully fetched release body for tag '{tag}'.")
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
        print("Warning: Found 'Package Info' section in previous release but no package list items were extracted.")
    return get_packages_dict(package_lines_for_parsing)


def main():
    parser = argparse.ArgumentParser(
        description="Generate changelog Markdown from package info.")
    parser.add_argument("--input-file", required=True,
                        help="Path to the text file with CURRENT build's package info.")
    parser.add_argument("--output-file", required=True,
                        help="Path to write the generated Markdown output.")
    parser.add_argument("--prev-tag", required=True,
                        help="Previous GitHub release tag of this project (e.g., '2025.04.27').")
    parser.add_argument("--current-build-tag", required=True,
                        help="Tag for the new release being built (e.g., '2025.06.09').")
    parser.add_argument("--github-owner", default="ehsan18t",
                        help="GitHub repository owner.")
    parser.add_argument(
        "--github-repo", default="easy-mingw-installer", help="GitHub repository name.")
    args = parser.parse_args()

    markdown_output: List[str] = []

    # --- Stage 1 & 2: Parse current input file ---
    current_package_lines_for_info_section: List[str] = []

    try:
        with open(args.input_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"Error: Input file not found: {args.input_file}")
        return

    in_package_list_section = False

    for line_content in lines:  # Simplified loop
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
            elif not line_strip:  # Allow empty lines
                # Or append if you want to preserve them: markdown_output.append("")
                pass
            # Check if it's the start of the next known sections
            elif line_strip.startswith("Thread model:") or \
                    line_strip.startswith("Runtime library:") or \
                    ("This build was compiled with GCC" in line_content and "and packaged on" in line_content):
                in_package_list_section = False  # End of package list
                markdown_output.append("")  # Add a blank line after the list
                # Fall through to process this line
            # If previous was a list item and this is not, end list
            elif markdown_output and markdown_output[-1].startswith("- "):
                in_package_list_section = False
                markdown_output.append("")

        # --- Stage 3: Extract Thread Model, Runtime Library, Build Date ---
        # This part now processes the line if in_package_list_section became false OR was already false
        if not in_package_list_section:  # Process only if not in the middle of the package list items
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
        print("Warning: Could not find or parse the package list from the input file.")
        # Ensure a blank line if header was added
        if markdown_output and markdown_output[-1] != "":
            markdown_output.append("")

    # --- Stage 4: Static Script Changelog ---
    markdown_output.append("## Script/Installer Changelogs")
    markdown_output.append("* None")
    markdown_output.append("")

    # --- Stage 5: Package Changelogs ---
    markdown_output.append("## Package Changelogs")

    previous_release_body_lines = get_github_release_body_lines(
        args.github_owner, args.github_repo, args.prev_tag)

    previous_packages_dict = get_packages_from_markdown_lines(
        previous_release_body_lines)
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
        if previous_release_body_lines and previous_packages_dict:
            markdown_output.append(
                f"* No package changes detected compared to the previous version (`{args.prev_tag}`).")
        elif previous_release_body_lines and not previous_packages_dict:
            markdown_output.append(
                f"* Previous release body for tag `'{args.prev_tag}`' was found but no package list could be parsed from it. All current packages listed as new if any.")
        else:
            markdown_output.append(
                "* Could not retrieve or parse previous version's package list; all current packages are listed as new if any.")
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
        print("Warning: Full changelog link might be incomplete.")

    markdown_output.append("")
    markdown_output.append("<br>")
    markdown_output.append("")
    markdown_output.append("### File Hash")

    try:
        with open(args.output_file, 'w', encoding='utf-8') as f:
            f.write("\n".join(markdown_output))
        print(f"Markdown file generated successfully: {args.output_file}")
    except IOError as e:
        print(f"Error writing output file: {e}")


if __name__ == "__main__":
    main()
