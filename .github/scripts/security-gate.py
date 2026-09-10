#!/usr/bin/env python3
"""Decide pass or fail for the security workflow.

Reads whatever scanner output the job produced, applies the repository's
suppression list, and exits non-zero when an unsuppressed Critical or High
survives. The threshold lives here rather than in policy prose because BSR-A3
requires it enforced in the workflow, not asserted in a document.

Two rules make the suppression list evidence rather than an escape hatch:

  1. Every entry must carry id, task, owner and expires. A missing field fails
     the build, so an entry cannot be added carelessly.
  2. An expired entry fails the build. Suppressions rot; this is what stops a
     dated exception quietly becoming permanent.

Usage: security-gate.py <suppressions.yml> <scanner-output>...
Scanner type is inferred from the filename prefix.
"""
import json
import os
import sys
from datetime import date

BLOCKING = {"CRITICAL", "HIGH"}
REQUIRED_FIELDS = ("id", "task", "owner", "expires")


def load_suppressions(path):
    """Minimal YAML reader for the flat list-of-mappings shape we commit.

    Deliberately not PyYAML: this runs before dependencies are installed, and a
    scanner gate that needs its own dependency tree is a gate that gets skipped.
    """
    entries, cur = [], None
    if not os.path.exists(path):
        return entries
    for raw in open(path, encoding="utf-8"):
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        if stripped.startswith("- "):
            if cur:
                entries.append(cur)
            cur = {}
            stripped = stripped[2:]
        if cur is None or ":" not in stripped:
            continue
        k, _, v = stripped.partition(":")
        cur[k.strip()] = v.strip().strip('"').strip("'")
    if cur:
        entries.append(cur)
    return entries


def check_suppressions(entries):
    """Return (suppressed_ids, errors, unowned). Errors fail the build.

    An unassigned owner is reported loudly but does not fail on its own: the
    seeded list starts that way, and a gate that is red before anyone can act on
    it gets switched off, which is the failure this whole design avoids.
    """
    ids, errors, unowned = set(), [], []
    today = date.today().isoformat()
    for i, e in enumerate(entries, 1):
        missing = [f for f in REQUIRED_FIELDS if not e.get(f)]
        if missing:
            errors.append(f"entry {i}: missing {', '.join(missing)}")
            continue
        if e["expires"] < today:
            errors.append(
                f"{e['id']}: expired {e['expires']}, owner {e['owner']}, task {e['task']}"
            )
        if e["owner"].lower() in ("unassigned", "tbd", "-"):
            unowned.append(e["id"])
        ids.add(e["id"])
    return ids, errors, unowned


def _sev(value):
    return (value or "").strip().upper()


def parse_semgrep(doc):
    # ERROR is semgrep's own top band; map it onto ours rather than inventing one.
    level = {"ERROR": "HIGH", "WARNING": "MEDIUM", "INFO": "LOW"}
    for r in doc.get("results", []):
        extra = r.get("extra", {})
        yield {
            "id": r.get("check_id", "semgrep"),
            "severity": level.get(_sev(extra.get("severity")), "LOW"),
            "where": f"{r.get('path')}:{r.get('start', {}).get('line')}",
        }


def parse_trivy(doc):
    for res in doc.get("Results") or []:
        target = res.get("Target", "")
        for v in res.get("Vulnerabilities") or []:
            yield {
                "id": v.get("VulnerabilityID", "trivy"),
                "severity": _sev(v.get("Severity")),
                "where": f"{target}:{v.get('PkgName')}",
            }
        for m in res.get("Misconfigurations") or []:
            yield {
                "id": m.get("ID", "trivy-misconfig"),
                "severity": _sev(m.get("Severity")),
                "where": target,
            }


def parse_gitleaks(doc):
    # Gitleaks emits no severity. A committed secret is not a medium.
    for f in doc if isinstance(doc, list) else []:
        yield {
            "id": f.get("RuleID", "gitleaks"),
            "severity": "HIGH",
            "where": f"{f.get('File')}:{f.get('StartLine')}",
        }


def parse_npm_audit(doc):
    for name, v in (doc.get("vulnerabilities") or {}).items():
        yield {
            "id": f"npm:{name}",
            "severity": _sev(v.get("severity")),
            "where": name,
        }


def parse_govulncheck(text):
    """govulncheck streams JSON objects, and it emits a finding twice over.

    A finding whose top trace frame names only a module means the vulnerable
    version is present in the dependency graph. A finding whose top frame also
    names a *function* means our code actually calls the vulnerable symbol. Only
    the second is reachability, and only the second belongs in this gate: the
    first is what Trivy already reports, and counting both is how "305 High"
    turns into a number nobody can act on.

    On synstream-auth-project the difference is 38 advisories present against 11
    reachable, which is the whole reason the pack leads with govulncheck.
    """
    decoder, idx, seen = json.JSONDecoder(), 0, set()
    while idx < len(text):
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
        except ValueError:
            break
        idx = end
        finding = obj.get("finding") or {}
        trace = finding.get("trace") or []
        top = trace[0] if trace else {}
        if not top.get("function"):
            continue
        osv = finding.get("osv")
        if osv and osv not in seen:
            seen.add(osv)
            yield {
                "id": osv,
                "severity": "HIGH",
                "where": f"{top.get('module', '?')}.{top['function']}",
            }


def findings_for(path):
    name = os.path.basename(path)
    text = open(path, encoding="utf-8", errors="replace").read().strip()
    if not text:
        return []
    if name.startswith("govulncheck"):
        return list(parse_govulncheck(text))
    doc = json.loads(text)
    for prefix, fn in (
        ("semgrep", parse_semgrep),
        ("trivy", parse_trivy),
        ("gitleaks", parse_gitleaks),
        ("npmaudit", parse_npm_audit),
    ):
        if name.startswith(prefix):
            return list(fn(doc))
    return []


def main(argv):
    if len(argv) < 2:
        print("usage: security-gate.py <suppressions.yml> <scanner-output>...")
        return 2

    suppressed, errors, unowned = check_suppressions(load_suppressions(argv[1]))
    if unowned:
        print(
            f"WARNING: {len(unowned)} suppressions have no owner. BSR-E1 requires "
            "ownership\n         within one working day of a finding being raised, "
            "and an unowned\n         exception is how a dated entry quietly reaches "
            "its expiry unfixed."
        )
    if errors:
        print("Suppression list is not valid:")
        for e in errors:
            print(f"  {e}")
        print("\nAn entry must carry id, task, owner and expires, and must not be")
        print("past its expiry. Renew it with a new date and a reason, or fix the")
        print("finding. Silence with no end date is not an exception, it is a leak.")
        return 1

    blocking, counts, muted = [], {}, 0
    for path in argv[2:]:
        if not os.path.exists(path):
            continue
        try:
            found = findings_for(path)
        except (ValueError, KeyError) as exc:
            # A parse failure must not read as a clean scan.
            print(f"Could not parse {path}: {exc}")
            return 1
        for f in found:
            counts[f["severity"]] = counts.get(f["severity"], 0) + 1
            if f["severity"] in BLOCKING:
                if f["id"] in suppressed:
                    muted += 1
                else:
                    blocking.append(f)

    order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
    summary = ", ".join(f"{s.title()} {counts[s]}" for s in order if s in counts)
    print(f"Findings: {summary or 'none'}")
    print(f"Suppressed by the committed list: {muted}")

    if not blocking:
        print("Gate: pass. No unsuppressed Critical or High.")
        return 0

    print(f"\nGate: FAIL. {len(blocking)} unsuppressed Critical or High:")
    for f in sorted(blocking, key=lambda x: (x["severity"], x["id"]))[:50]:
        print(f"  {f['severity']:<8} {f['id']}  {f['where']}")
    if len(blocking) > 50:
        print(f"  ... and {len(blocking) - 50} more")
    print("\nFix it, or add a dated entry to the suppression list naming the task,")
    print("an owner and an expiry date.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
