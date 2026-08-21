#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <owner/repo> <specification-package-root>" >&2
    exit 64
fi

github_repo="$1"
spec_root="$2"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
trace_file="$repository_root/docs/REQUIREMENT_TRACEABILITY_1.0.csv"
expected_header="requirement_id,requirement,authoritative_specs,implementation_issues,evidence_gate_issues,required_evidence"

command -v gh >/dev/null 2>&1 || {
    echo "gh is required to validate live issue references" >&2
    exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
    echo "sha256sum is required to validate specification integrity" >&2
    exit 1
}

[[ -d "$spec_root" ]] || {
    echo "specification package root does not exist: $spec_root" >&2
    exit 1
}
[[ -f "$spec_root/SHA256SUMS" ]] || {
    echo "specification package has no SHA256SUMS: $spec_root" >&2
    exit 1
}
(
    cd -- "$spec_root"
    sha256sum -c SHA256SUMS >/dev/null
) || {
    echo "specification package checksum validation failed: $spec_root" >&2
    exit 1
}

[[ -f "$trace_file" ]] || {
    echo "traceability file does not exist: $trace_file" >&2
    exit 1
}

actual_header="$(head -n 1 "$trace_file")"
[[ "$actual_header" == "$expected_header" ]] || {
    echo "unexpected traceability header" >&2
    exit 1
}

awk -F, '
    NF != 6 {
        printf "traceability line %d has %d columns; expected 6\n", NR, NF > "/dev/stderr"
        invalid = 1
    }
    END { exit invalid }
' "$trace_file"

declare -A issue_slugs=()
declare -A seen_requirement_ids=()
row_count=0

register_issue_references() {
    local role="$1"
    local requirement_id="$2"
    local references="$3"
    local reference
    local issue_number
    local issue_slug
    local previous_slug
    local -a reference_list

    IFS=';' read -r -a reference_list <<< "$references"
    for reference in "${reference_list[@]}"; do
        if [[ ! "$reference" =~ ^([1-9][0-9]*):([a-z0-9][a-z0-9.-]*)$ ]]; then
            echo "$requirement_id has invalid $role issue reference: $reference" >&2
            exit 1
        fi

        issue_number="${BASH_REMATCH[1]}"
        issue_slug="${BASH_REMATCH[2]}"
        if [[ "$role" == "evidence" ]] &&
            (( issue_number < 46 || issue_number > 50 )); then
            echo "$requirement_id evidence issue #$issue_number is outside #46-#50" >&2
            exit 1
        fi

        previous_slug="${issue_slugs[$issue_number]-}"
        if [[ -n "$previous_slug" && "$previous_slug" != "$issue_slug" ]]; then
            echo "issue #$issue_number has conflicting slugs: $previous_slug and $issue_slug" >&2
            exit 1
        fi
        issue_slugs[$issue_number]="$issue_slug"
    done
}

while IFS=, read -r requirement_id requirement authoritative_specs \
    implementation_issues evidence_gate_issues required_evidence; do
    [[ "$requirement_id" == "requirement_id" ]] && continue

    row_count=$((row_count + 1))
    expected_id="$(printf 'R-%03d' "$row_count")"
    [[ "$requirement_id" == "$expected_id" ]] || {
        echo "expected requirement $expected_id; found $requirement_id" >&2
        exit 1
    }
    [[ -z "${seen_requirement_ids[$requirement_id]-}" ]] || {
        echo "duplicate requirement ID: $requirement_id" >&2
        exit 1
    }
    seen_requirement_ids[$requirement_id]=1

    for required_field in "$requirement" "$authoritative_specs" \
        "$implementation_issues" "$evidence_gate_issues" "$required_evidence"; do
        [[ -n "$required_field" ]] || {
            echo "$requirement_id has an empty required field" >&2
            exit 1
        }
    done

    IFS=';' read -r -a spec_list <<< "$authoritative_specs"
    for spec_path in "${spec_list[@]}"; do
        if [[ "$spec_path" == /* || "$spec_path" == *".."* ]]; then
            echo "$requirement_id has an unsafe specification path: $spec_path" >&2
            exit 1
        fi
        [[ -f "$spec_root/$spec_path" ]] || {
            echo "$requirement_id specification does not exist: $spec_path" >&2
            exit 1
        }
    done

    register_issue_references implementation "$requirement_id" "$implementation_issues"
    register_issue_references evidence "$requirement_id" "$evidence_gate_issues"
done < "$trace_file"

(( row_count > 0 )) || {
    echo "traceability matrix has no requirements" >&2
    exit 1
}

for issue_number in "${!issue_slugs[@]}"; do
    # The jq program is literal; shell expansion would be incorrect here.
    # shellcheck disable=SC2016
    live_slug="$(
        gh issue view "$issue_number" \
            --repo "$github_repo" \
            --json body \
            --jq '.body | capture("\\*\\*Slug:\\*\\* `(?<slug>[^`]+)`").slug'
    )"
    [[ "$live_slug" == "${issue_slugs[$issue_number]}" ]] || {
        echo "issue #$issue_number expected slug ${issue_slugs[$issue_number]}; found $live_slug" >&2
        exit 1
    }
done

printf 'validated %d requirements, %d package specs, and %d live issue references\n' \
    "$row_count" \
    "$(tail -n +2 "$trace_file" | cut -d, -f3 | tr ';' '\n' | sort -u | wc -l)" \
    "${#issue_slugs[@]}"
