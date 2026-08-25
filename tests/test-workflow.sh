#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WF=${1:-"$ROOT/.github/workflows/build-e87n.yml"}
ACTIONLINT=${ACTIONLINT:-actionlint}
PYTHON=${PYTHON:-python3}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
test -f "$WF" || fail "missing $WF"
command -v "$ACTIONLINT" >/dev/null 2>&1 || fail 'actionlint is required'
command -v "$PYTHON" >/dev/null 2>&1 || fail 'Python 3 is required'
"$PYTHON" -c 'import yaml; assert hasattr(yaml, "safe_load")' >/dev/null 2>&1 || fail 'PyYAML is required'

CHECKER=$(mktemp "${TMPDIR:-/tmp}/e87n-workflow-check.XXXXXX.py")
MUTATIONS=$(mktemp -d "${TMPDIR:-/tmp}/e87n-workflow-mutations.XXXXXX")
trap 'rm -f "$CHECKER"; rm -rf "$MUTATIONS"' EXIT HUP INT TERM

cat >"$CHECKER" <<'PY'
import re
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
raw = path.read_text(encoding="utf-8")
workflow = yaml.safe_load(raw)

def check(condition, message):
    if not condition:
        raise AssertionError(message)

def named_steps(job):
    result = {}
    for step in job.get("steps", []):
        name = step.get("name")
        if name:
            check(name not in result, f"duplicate step name: {name}")
            result[name] = step
    return result

def executable_lines(script):
    physical = []
    for original in script.splitlines():
        stripped = original.strip()
        if not stripped or stripped.startswith("#"):
            continue
        physical.append(stripped)
    logical = []
    pending = ""
    for line in physical:
        pending = f"{pending} {line}".strip()
        if pending.endswith("\\"):
            pending = pending[:-1].rstrip()
        else:
            logical.append(pending)
            pending = ""
    check(not pending, "run block ends with a dangling continuation")
    return logical

def flat_executable_lines(script, label):
    lines = executable_lines(script)
    check(lines and lines[0] == "set -euo pipefail", f"{label} must begin with exact fail-fast shell options")
    depth = 0
    records = []
    for index, line in enumerate(lines):
        closer = re.fullmatch(r"(?:fi|done|esac|\}|\))", line)
        if closer:
            depth -= 1
            check(depth >= 0, f"{label} has an unmatched shell closer: {line}")
        records.append((line, depth, bool(closer)))
        opener = (
            re.fullmatch(r"if .+; then", line)
            or re.fullmatch(r"(?:for|while|until) .+; do", line)
            or re.fullmatch(r"case .+ in", line)
            or re.fullmatch(r"(?:function[ ]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ ]*\{", line)
            or re.fullmatch(r"[({]", line)
        )
        if opener:
            depth += 1
        check("<<" not in line.replace("<<<", ""), f"{label} contains an ambiguous here-document")
        check("&&" not in line and "||" not in line, f"{label} contains boolean short-circuit control")
        set_command = re.search(r"(?:^|;[ ]*)(?:(?:builtin|command)[ ]+)?set(?:[ ]|;|$)", line)
        check(not set_command or (index == 0 and line == "set -euo pipefail"),
              f"{label} mutates shell options after the fail-fast preamble: {line}")
        bypass = re.search(r"(?:^|;[ ]*)(?:[A-Za-z_][A-Za-z0-9_]*=[^ ]+[ ]+)*(?:(?:builtin|command)[ ]+)?(?:exit|exec|return|trap)(?:[ ]|;|$)", line)
        check(not bypass, f"{label} contains an early termination or trap bypass: {line}")
    check(depth == 0, f"{label} has unbalanced shell control flow")
    for line, command_depth, is_closer in records:
        check(command_depth == 0 and not is_closer, f"{label} contains nested/compound shell control: {line}")
    return [line for line, _, _ in records]

def require_ordered(lines, requirements, label):
    cursor = -1
    for pattern in requirements:
        for index in range(cursor + 1, len(lines)):
            if re.fullmatch(pattern, lines[index]):
                cursor = index
                break
        else:
            raise AssertionError(f"{label} lacks ordered executable command: {pattern}")

check(isinstance(workflow, dict), "workflow must parse as a mapping")
check(workflow.get("permissions") == {"contents": "read"}, "top permissions must be contents: read only")
check(workflow.get("concurrency") == {
    "group": "e87n-${{ github.workflow }}-${{ github.ref }}",
    "cancel-in-progress": True,
}, "concurrency must be workflow/ref scoped with cancellation")

dispatch = workflow.get("on", {}).get("workflow_dispatch", {})
inputs = dispatch.get("inputs", {})
check(set(inputs) == {"profiles", "publish_release", "make_jobs"}, "dispatch inputs are not exact")
check(inputs["profiles"].get("type") == "choice", "profiles must be a choice")
check(inputs["profiles"].get("options") == ["both", "full", "rescue"], "profile choices are not exact")
check(inputs["publish_release"].get("type") == "boolean", "publish_release must be boolean")
check(inputs["publish_release"].get("default") is False, "publish_release must default false")
check(inputs["make_jobs"].get("type") == "string", "make_jobs must be strictly validated as a string")

jobs = workflow.get("jobs", {})
check(set(jobs) == {"plan", "build", "release"}, "workflow jobs are not exact")
for job_name in ("plan", "build"):
    check(jobs[job_name].get("permissions") == {"contents": "read"}, f"{job_name} must be read-only")
check(jobs["release"].get("permissions") == {"contents": "write"}, "release alone must receive contents: write")
check(jobs["build"].get("needs") == "plan", "build must need plan")
check(jobs["release"].get("needs") == ["plan", "build"], "release must need plan and aggregate matrix build")
check(jobs["build"].get("runs-on") == "ubuntu-24.04", "build runner must be ubuntu-24.04")
check(jobs["build"].get("timeout-minutes") == 350, "build timeout must be 350 minutes")
check(jobs["release"].get("if") == "${{ inputs.publish_release == true && inputs.profiles != 'rescue' }}",
      "release condition is not exact")
check(jobs["build"].get("strategy", {}).get("matrix", {}).get("profile") ==
      "${{ fromJSON(needs.plan.outputs.profiles) }}", "profile matrix expression is not exact")

approved = {
    "actions/checkout": ("11bd71901bbe5b1630ceea73d27597364c9af683", "v4.2.2", 2),
    "actions/cache": ("5a3ec84eff668545956fd18022155c47e93e2684", "v4.2.3", 1),
    "actions/upload-artifact": ("ea165f8d65b6e75b540449e92b4886f43607fa02", "v4.6.2", 1),
    "actions/download-artifact": ("d3f86a106a0bac45b974a628896c90dbdf5c8093", "v4.3.0", 2),
}
seen = {name: 0 for name in approved}
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        uses = step.get("uses")
        if uses is None:
            continue
        match = re.fullmatch(r"([^@]+)@([0-9a-f]{40})", uses)
        check(match is not None, f"{job_name} has a non-immutable action reference: {uses}")
        owner_action, sha = match.groups()
        check(owner_action in approved, f"unapproved action owner/name: {owner_action}")
        check(sha == approved[owner_action][0], f"unreviewed SHA for {owner_action}: {sha}")
        seen[owner_action] += 1
check(all(seen[name] == values[2] for name, values in approved.items()), f"action counts are not exact: {seen}")
for owner_action, (sha, tag, count) in approved.items():
    line = re.compile(rf"^[ ]+uses: {re.escape(owner_action)}@{sha}[ ]+# {re.escape(tag)}$", re.MULTILINE)
    check(len(line.findall(raw)) == count, f"{owner_action} pins lack exact {tag} provenance comments")

plan_steps = named_steps(jobs["plan"])
selector = flat_executable_lines(plan_steps["Validate inputs and select profiles"].get("run", ""), "input selector")
require_ordered(selector, [
    r'set -euo pipefail',
    r'\[\[ "\$REQUESTED_MAKE_JOBS" =~ \^\[1-9\]\[0-9\]\*\$ \]\]',
    r'profiles=\$\(python3 -c .+ "\$SELECTED_PROFILES"\)',
    r'source versions\.env',
    r'\[\[ "\$IMMORTALWRT_COMMIT" =~ \^\[0-9a-f\]\{40\}\$ \]\]',
    r'printf \'profiles=%s\\n\' "\$profiles" >> "\$GITHUB_OUTPUT"',
    r'printf \'make_jobs=%s\\n\' "\$REQUESTED_MAKE_JOBS" >> "\$GITHUB_OUTPUT"',
    r'printf \'immortalwrt_commit=%s\\n\' "\$IMMORTALWRT_COMMIT" >> "\$GITHUB_OUTPUT"',
], "input selector")
selector_text = "\n".join(selector)
for mapping in ('"both":["full","rescue"]', '"full":["full"]', '"rescue":["rescue"]'):
    check(mapping in selector_text, f"profile mapping missing: {mapping}")

steps = jobs["build"].get("steps", [])
names = [step.get("name") for step in steps]
ordered_steps = [
    "Static checks before source preparation",
    "Prepare locked source and feeds",
    "Cache locked source downloads",
    "Resolve locked configuration policy",
    "Build and collect validated profile",
    "Verify exact profile publication",
    "Upload validated profile",
]
check(all(name in names for name in ordered_steps), "required build step is missing")
check([names.index(name) for name in ordered_steps] == sorted(names.index(name) for name in ordered_steps),
      "static/source/cache/policy/build/publication ordering is unsafe")
build_steps = named_steps(jobs["build"])

static_lines = flat_executable_lines(build_steps["Static checks before source preparation"].get("run", ""), "static gate")
require_ordered(static_lines, [
    r'set -euo pipefail',
    r'actionlint \.github/workflows/build-e87n\.yml',
    r'shellcheck scripts/\*\.sh scripts/lib/\*\.sh tests/\*\.sh',
    r'bash tests/test-build-scripts\.sh',
    r'bash tests/test-config-fragments\.sh',
    r'bash tests/test-e87n-platform\.sh',
    r'bash tests/test-fancontrol-package\.sh',
    r'bash tests/test-kernel-requirements\.sh',
    r'bash tests/test-prepare-source\.sh',
    r'sh tests/test-rust-toolchain-policy\.sh',
    r'bash tests/test-repository-safety\.sh',
    r'bash tests/test-workflow\.sh',
], "static gate")

prepare_lines = flat_executable_lines(build_steps["Prepare locked source and feeds"].get("run", ""), "source preparation")
require_ordered(prepare_lines, [r'set -euo pipefail', r'WORK_DIR="\$GITHUB_WORKSPACE/work" bash scripts/prepare-source\.sh'], "source preparation")

cache_steps = [step for step in steps if step.get("uses", "").startswith("actions/cache@")]
check(len(cache_steps) == 1, "there must be exactly one cache action")
cache = cache_steps[0].get("with", {})
check(cache == {
    "path": "work/immortalwrt/dl",
    "key": "${{ runner.os }}-immortalwrt-dl-${{ env.IMMORTALWRT_COMMIT }}",
}, "cache scope/key must be exact and commit-evaluated")

policy_lines = flat_executable_lines(build_steps["Resolve locked configuration policy"].get("run", ""), "resolved policy gate")
require_ordered(policy_lines, [
    r'set -euo pipefail',
    r'policy_output=\$\(IMMORTALWRT_SOURCE="\$GITHUB_WORKSPACE/work/immortalwrt" bash tests/test-config-fragments\.sh\)',
    r'printf \'%s\\n\' "\$policy_output"',
    r'awk \'/\^SKIP:/ \{ bad=1 \} END \{ exit bad \}\' <<< "\$policy_output"',
    r'grep -qx \'PASS: resolved full and rescue configs\' <<< "\$policy_output"',
], "resolved policy gate")

build_lines = flat_executable_lines(build_steps["Build and collect validated profile"].get("run", ""), "build/validator gate")
require_ordered(build_lines, [
    r'set -euo pipefail',
    r'PATH="\$install_dir:\$PATH" E87N_MAKE_JOBS="\$MAKE_JOBS" WORK_DIR="\$GITHUB_WORKSPACE/work" bash scripts/build-e87n\.sh "\$PROFILE"',
    r'IMMORTALWRT_SOURCE="\$GITHUB_WORKSPACE/work/immortalwrt" bash scripts/validate-e87n\.sh "\$PROFILE" > "\$RUNNER_TEMP/e87n-validation-second-pass"',
    r'cmp "\$RUNNER_TEMP/e87n-validation-second-pass" "out/\$PROFILE/VALIDATION\.txt"',
], "build/validator gate")

def verify_gate(step, label, base_pattern, directory_pattern, profile_value):
    lines = flat_executable_lines(step.get("run", ""), label)
    require_ordered(lines, [
        r'set -euo pipefail',
        base_pattern,
        directory_pattern,
        r'expected_files=\$\(printf \'%s\\n\' BUILD-MANIFEST\.txt SHA256SUMS VALIDATION\.txt "\$base-sysupgrade\.bin" "\$base\.config" "\$base\.manifest" \| sort\)',
        r'actual_files=\$\(find "\$profile_dir" -mindepth 1 -maxdepth 1 -printf \'%f\\n\' \| sort\)',
        r'test "\$actual_files" = "\$expected_files"',
        r'non_regular=\$\(find "\$profile_dir" -mindepth 1 -maxdepth 1 ! -type f -printf \'%f\\n\'\)',
        r'test -z "\$non_regular"',
        r'pushd "\$profile_dir"',
        r'sha256sum -c SHA256SUMS',
        r'grep -qx \'VALIDATION=PASS\' VALIDATION\.txt',
        rf'grep -qx [\'\"]PROFILE={profile_value}[\'\"] BUILD-MANIFEST\.txt',
        r'popd',
    ], label)

verify_gate(
    build_steps["Verify exact profile publication"],
    "build publication gate",
    r'base="edgepi-e87n-immortalwrt-25\.12-\$PROFILE"',
    r'profile_dir="out/\$PROFILE"',
    r'\$PROFILE',
)
upload_steps = [step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@")]
check(len(upload_steps) == 1, "build must upload exactly one artifact")
check(upload_steps[0].get("with") == {
    "name": "e87n-${{ matrix.profile }}",
    "path": "out/${{ matrix.profile }}",
    "if-no-files-found": "error",
    "retention-days": 14,
    "include-hidden-files": False,
}, "artifact upload contract is not exact")

release_steps = named_steps(jobs["release"])
for profile in ("full", "rescue"):
    check(release_steps[f"Download {profile} profile"].get("with") == {
        "name": f"e87n-{profile}",
        "path": f"release-input/{profile}",
    }, f"{profile} download path/name is not exact")
check("if" not in release_steps["Download full profile"], "full download must always run in a publishable release")
check(release_steps["Download rescue profile"].get("if") == "${{ inputs.profiles == 'both' }}",
      "rescue download must run only for the combined release")
verify_gate(
    release_steps["Verify downloaded full profile"],
    "full release verification gate",
    r"base='edgepi-e87n-immortalwrt-25\.12-full'",
    r"profile_dir='release-input/full'",
    "full",
)
verify_gate(
    release_steps["Verify downloaded rescue profile"],
    "rescue release verification gate",
    r"base='edgepi-e87n-immortalwrt-25\.12-rescue'",
    r"profile_dir='release-input/rescue'",
    "rescue",
)
check(release_steps["Verify downloaded rescue profile"].get("if") == "${{ inputs.profiles == 'both' }}",
      "rescue verification must run only for the combined release")

for step_name, condition, assets in (
    ("Create validated full release", "${{ inputs.profiles == 'full' }}",
     r'"release-input/full/edgepi-e87n-immortalwrt-25\.12-full-sysupgrade\.bin"'),
    ("Create validated combined release", "${{ inputs.profiles == 'both' }}",
     r'"release-input/full/edgepi-e87n-immortalwrt-25\.12-full-sysupgrade\.bin" "release-input/rescue/edgepi-e87n-immortalwrt-25\.12-rescue-sysupgrade\.bin"'),
):
    release_create = release_steps[step_name]
    check(release_create.get("if") == condition, f"{step_name} condition is not exact")
    check(release_create.get("env") == {"GH_TOKEN": "${{ github.token }}"},
          f"{step_name} must use only github.token")
    release_lines = flat_executable_lines(release_create.get("run", ""), step_name)
    require_ordered(release_lines, [
        r'set -euo pipefail',
        r'short_sha=\$\{GITHUB_SHA:0:12\}',
        r'tag="e87n-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}-\$short_sha"',
        rf'gh release create "\$tag" --repo "\$GITHUB_REPOSITORY" {assets} --target "\$GITHUB_SHA" --title "\$title" --notes .+',
    ], step_name)
check("secrets." not in raw, "workflow references an external secret")
PY

check_workflow() {
  "$ACTIONLINT" "$1"
  "$PYTHON" "$CHECKER" "$1"
}

check_workflow "$WF"

# A direct checker invocation is used by the mutation harness itself.
if test "${2:-}" = --check-only; then
  exit 0
fi

"$PYTHON" - "$WF" "$MUTATIONS" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
workflow = source.read_text(encoding="utf-8")

def write(name, text):
    (destination / f"{name}.yml").write_text(text, encoding="utf-8")

def replace_exact(text, old, new):
    if text.count(old) != 1:
        raise AssertionError(f"mutation anchor is not unique: {old}")
    return text.replace(old, new)

def replace_after(text, marker, old, new):
    if text.count(marker) != 1:
        raise AssertionError(f"mutation marker is not unique: {marker}")
    before, after = text.split(marker, 1)
    if old not in after:
        raise AssertionError(f"mutation anchor missing after {marker}: {old}")
    return before + marker + after.replace(old, new, 1)

write("mutable-action", replace_exact(
    workflow,
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2",
    "actions/upload-artifact@v4 # v4.6.2",
))

write("literal-cache-pin", replace_exact(
    workflow,
    "${{ runner.os }}-immortalwrt-dl-${{ env.IMMORTALWRT_COMMIT }}",
    "${{ runner.os }}-immortalwrt-dl-IMMORTALWRT_COMMIT",
))

write("unevaluated-cache-pin", replace_exact(
    workflow,
    "${{ runner.os }}-immortalwrt-dl-${{ env.IMMORTALWRT_COMMIT }}",
    "${{ runner.os }}-immortalwrt-dl-$IMMORTALWRT_COMMIT",
))

write("commented-resolved-gate", replace_exact(
    workflow,
    "          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
    "          # grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
))

write("removed-resolved-gate", replace_exact(
    workflow,
    "          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"\n",
    "",
))

write("dead-resolved-gate", replace_exact(
    workflow,
    "          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
    "          if false; then\n            grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"\n          fi",
))

write("short-circuit-resolved-gate", replace_exact(
    workflow,
    "          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
    "          false && grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
))

write("early-exit-resolved-gate", replace_exact(
    workflow,
    "          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
    "          exit 0\n          grep -qx 'PASS: resolved full and rescue configs' <<< \"$policy_output\"",
))

release_marker = "      - name: Verify downloaded full profile"

write("weak-release-sha", replace_after(
    workflow,
    release_marker,
    "          sha256sum -c SHA256SUMS",
    "          sha256sum SHA256SUMS",
))

write("dead-release-sha", replace_after(
    workflow,
    release_marker,
    "          sha256sum -c SHA256SUMS",
    "          if false; then\n            sha256sum -c SHA256SUMS\n          fi",
))

write("short-circuit-release-sha", replace_after(
    workflow,
    release_marker,
    "          sha256sum -c SHA256SUMS",
    "          true || sha256sum -c SHA256SUMS",
))

write("weak-release-exact-files", replace_after(
    workflow,
    release_marker,
    '          test "$actual_files" = "$expected_files"',
    '          : "$actual_files $expected_files"',
))

write("dead-release-exact-files", replace_after(
    workflow,
    release_marker,
    '          test "$actual_files" = "$expected_files"',
    '          if false; then\n            test "$actual_files" = "$expected_files"\n          fi',
))

write("early-exec-release-exact-files", replace_after(
    workflow,
    release_marker,
    '          test "$actual_files" = "$expected_files"',
    '          exec true\n          test "$actual_files" = "$expected_files"',
))

write("disable-errexit-release-gates", replace_after(
    workflow,
    release_marker,
    "          sha256sum -c SHA256SUMS",
    "          set +e\n          sha256sum -c SHA256SUMS",
))

write("trap-release-gate-errors", replace_after(
    workflow,
    release_marker,
    "          sha256sum -c SHA256SUMS",
    "          trap 'exit 0' ERR\n          sha256sum -c SHA256SUMS",
))
PY

for mutation in "$MUTATIONS"/*.yml; do
  if check_workflow "$mutation" >"$mutation.stdout" 2>"$mutation.stderr"; then
    fail "mutation unexpectedly accepted: ${mutation##*/}"
  fi
done

printf '%s\n' 'PASS: E87N GitHub Actions workflow policy and mutations'
