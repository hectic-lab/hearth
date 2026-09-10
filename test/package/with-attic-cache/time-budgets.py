import os
import re
import subprocess

import yaml


def need(condition, message):
    if not condition:
        raise AssertionError(message)


def minutes(value):
    text = str(value)
    match = re.fullmatch(r"(\d+)([smh])?", text)
    if match is None:
        raise AssertionError(f"invalid duration: {text}")
    amount = int(match.group(1))
    unit = match.group(2) or "m"
    return amount // 60 if unit == "s" else amount * 60 if unit == "h" else amount


def dash(script):
    return subprocess.check_output(
        [os.environ["DASH"], "-eu", "-c", script],
        text=True,
        env=os.environ,
    ).strip()


def workflow_budget(path):
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    job = data["jobs"]["deploy"]
    step = next(s for s in job["steps"] if s.get("name") == "Deploy neuro")
    env = step["env"]
    return {
        "label": job["runs-on"],
        "workflow": int(job["timeout-minutes"]),
        "build": int(env["WITH_ATTIC_BUILD_TIMEOUT"]) // 60,
        "drain": int(env["WITH_ATTIC_DRAIN_TIMEOUT"]) // 60,
        "upload": int(env["WITH_ATTIC_UPLOAD_TIMEOUT"]) // 60,
    }


def shell_budgets(label):
    source = f'. "$DECIDE_SH"; . "$CONTROLLER_SH"; . "$HCLOUD_SH"; '
    ttl = int(dash(source + f'gcr_label_ttl "{label}"'))
    profile = dash(source + f'gcr_label_profile "{label}"')
    grace = int(dash(source + 'gcr_ttl_grace_sec')) // 60
    script = source + f'gcr_bootstrap_script "{label}" token {ttl} runner'
    rendered = dash(script)
    match = re.search(r"runner:\n(?:  .*\n)*  timeout: (\d+)m\n", rendered)
    if match is None:
        raise AssertionError("runner timeout missing in rendered bootstrap")
    label_line = f'  - "{label}:host"'
    need(label_line in rendered, "runner label missing in rendered bootstrap")
    labels = "gross-x86 gross-arm gross-x86-perf gross-mixed-econ " \
        "gross-nix-x86 gross-nix-arm gross-nix-mixed-econ"
    others = dash(source + f"for l in {labels}; do "
                  "printf '%s=%s\\n' \"$l\" \"$(gcr_label_ttl \"$l\")\"; done")
    return ttl, profile, grace, int(match.group(1)), others.splitlines()


budget = workflow_budget(os.environ["WORKFLOW_FILE"])
need(budget["label"] == "gross-nix-x86-perf", "unexpected deployment runner label")
need(budget["build"] > 0 and budget["drain"] > 0 and budget["upload"] > 0, "non-positive timeout")
need(budget["build"] + budget["drain"] + 15 <= budget["workflow"], "workflow too short for build+drain")

ttl, profile, grace, runner_timeout, other_ttls = shell_budgets(budget["label"])
need(ttl == 480, f"expected 480m ttl, got {ttl}")
need(profile.split()[1] == "480", f"profile ttl drifted: {profile}")
need(all(line.endswith("=180") for line in other_ttls), f"default ttl drift: {other_ttls}")
need(budget["workflow"] < runner_timeout, "workflow must be below runner timeout")
need(minutes(os.environ["GITEA_WATCHDOG"]) >= budget["workflow"], "Gitea watchdog too short")
need(ttl + grace >= budget["workflow"] + 15, "VM ttl lacks bootstrap allowance")

print(f"PASS build={budget['build']}m drain={budget['drain']}m upload={budget['upload']}m workflow={budget['workflow']}m runner={runner_timeout}m ttl={ttl}m grace={grace}m watchdog={os.environ['GITEA_WATCHDOG']}")
