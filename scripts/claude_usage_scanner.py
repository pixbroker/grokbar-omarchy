#!/usr/bin/env python3
"""Scan Claude Code rate-limit windows for the Omarchy bar widget.

Reads the local Claude Code OAuth login (~/.claude/.credentials.json) and
calls Anthropic's usage endpoint. Session (5-hour) and weekly pools are the
primary meters; model-scoped windows (for example Fable Weekly) travel in
`limits`. Tokens are never logged or written to scanner JSON.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULT_CONFIG = Path.home() / ".claude"
DESKTOP_HISTORY = Path.home() / ".config" / "Claude" / "plan-usage-history.json"
USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "grokbar-omarchy/1.9"
AUTH_HELP = "Run `claude auth login` or sign in to the Claude desktop app."

SESSION_MS = 5 * 3600 * 1000
WEEK_MS = 7 * 24 * 3600 * 1000
MONTH_MS = 30 * 24 * 3600 * 1000


def empty_result(**overrides):
  out = {
    "ready": True,
    "rateLimitPercent": -1,
    "rateLimitLabel": "Session",
    "rateLimitResetAt": "",
    "rateLimitPeriodStart": "",
    "secondaryRateLimitPercent": -1,
    "secondaryRateLimitLabel": "Weekly",
    "secondaryRateLimitResetAt": "",
    "secondaryRateLimitPeriodStart": "",
    "tierLabel": "",
    "accountName": "",
    "accountEmail": "",
    "usageStatusText": "",
    "authHelpText": "",
    "limits": [],
  }
  out.update(overrides)
  return out


def expand_path(value, default):
  text = str(value or "").strip()
  if not text:
    return default
  return Path(os.path.expanduser(text)).expanduser()


def emit(payload):
  print(json.dumps(payload, separators=(",", ":")))
  return 0


def plan_label(tier, subscription):
  if tier:
    match = re.search(r"max_(\d+x)", str(tier), re.IGNORECASE)
    if match:
      return "Max " + match.group(1)
  text = str(subscription or "").strip()
  if not text:
    return ""
  return text[0].upper() + text[1:]


def load_oauth(config_dir):
  try:
    data = json.loads((config_dir / ".credentials.json").read_text(encoding="utf-8"))
  except Exception:
    return None
  login = data.get("claudeAiOauth")
  if not isinstance(login, dict):
    return None
  token = str(login.get("accessToken") or "").strip()
  if not token:
    return None
  expires_at = 0
  try:
    expires_at = int(login.get("expiresAt") or 0)
  except (TypeError, ValueError):
    expires_at = 0
  profile = load_profile(config_dir)
  return {
    "token": token,
    "expires_at": expires_at,
    "tier": profile.get("tier") or plan_label(login.get("rateLimitTier"), login.get("subscriptionType")),
    "name": profile.get("name") or "",
    "email": profile.get("email") or "",
  }


def load_profile(config_dir):
  """Account name/email and live tier from Claude Code's profile, if present."""
  candidates = [
    Path.home() / ".claude.json",
    Path(config_dir) / ".claude.json",
    Path(config_dir).parent / ".claude.json",
  ]
  for path in candidates:
    try:
      data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
      continue
    if not isinstance(data, dict):
      continue
    oauth = data.get("oauthAccount")
    if not isinstance(oauth, dict):
      continue
    name = str(oauth.get("fullName") or oauth.get("displayName") or "").strip()
    email = str(oauth.get("emailAddress") or oauth.get("email") or "").strip()
    tier = plan_label(
      oauth.get("organizationRateLimitTier") or oauth.get("userRateLimitTier"),
      oauth.get("organizationType") or oauth.get("subscriptionType"),
    )
    return {"name": name, "email": email, "tier": tier}
  return {}


def load_desktop_history():
  """Claude desktop writes five-hour/weekly utilization here when signed in."""
  try:
    data = json.loads(DESKTOP_HISTORY.read_text(encoding="utf-8"))
  except Exception:
    return None
  samples = data.get("samples") if isinstance(data, dict) else None
  if not isinstance(samples, list) or not samples:
    return None
  latest = samples[-1]
  if not isinstance(latest, dict):
    return None
  usage = latest.get("u")
  if not isinstance(usage, dict):
    return None
  # Desktop stores: fh=five_hour, sd=seven_day.
  limits = []
  fh = usage.get("fh")
  sd = usage.get("sd")
  if fh is not None:
    percent = normalize_utilization(fh, False)
    if percent >= 0:
      limits.append(limit_entry("Session", percent, "", "session"))
  if sd is not None:
    percent = normalize_utilization(sd, False)
    if percent >= 0:
      limits.append(limit_entry("Weekly", percent, "", "week"))
  if not limits:
    return None
  return {"limits": limits, "tier": "Claude"}


def parse_utilization(value):
  try:
    return float(str(value).strip().replace("%", ""))
  except Exception:
    return float("nan")


def normalize_utilization(value, percent_scale):
  n = parse_utilization(value)
  if not (n >= 0):
    return -1.0
  if percent_scale or n > 1:
    return min(1.0, n / 100.0)
  return min(1.0, n)


def normalize_reset_at(value):
  if value is None:
    return ""
  raw = str(value).strip()
  if raw == "":
    return ""
  if raw.isdigit():
    ts = int(raw)
    if ts < 1e12:
      ts *= 1000
    try:
      return datetime.fromtimestamp(ts / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
      return raw
  try:
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
      parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
  except Exception:
    return raw


def window_kind(kind, label):
  text = (str(kind or "") + " " + str(label or "")).lower()
  if "month" in text:
    return "month"
  if "week" in text or "7-day" in text or "7 day" in text:
    return "week"
  if "hour" in text or "session" in text:
    return "session"
  return "week"


def window_period_ms(kind):
  if kind == "session":
    return SESSION_MS
  if kind == "month":
    return MONTH_MS
  return WEEK_MS


def period_start_iso(reset_iso, period_ms):
  text = str(reset_iso or "").strip()
  if text == "" or not (period_ms > 0):
    return ""
  try:
    reset = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if reset.tzinfo is None:
      reset = reset.replace(tzinfo=timezone.utc)
    start = reset - timedelta(milliseconds=period_ms)
    return start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
  except Exception:
    return ""


def limit_entry(title, percent, reset_iso, kind):
  period_ms = window_period_ms(kind)
  return {
    "title": title,
    "percent": percent,
    "resetAt": reset_iso,
    "periodStart": period_start_iso(reset_iso, period_ms),
    "kind": kind,
    "dayCount": 0 if kind != "week" else 7,
  }


def usage_bucket(payload, key):
  bucket = payload.get(key)
  return bucket if isinstance(bucket, dict) else None


def scoped_limits(payload, percent_scale):
  entries = payload.get("limits")
  if not isinstance(entries, list):
    return []
  out = []
  seen = set()
  for entry in entries:
    if not isinstance(entry, dict):
      continue
    scope = entry.get("scope")
    model = scope.get("model") if isinstance(scope, dict) else None
    if not isinstance(model, dict):
      continue
    name = str(model.get("display_name") or model.get("id") or "").strip()
    kind_raw = str(entry.get("kind") or "").strip()
    if name == "" or (name, kind_raw) in seen:
      continue
    percent = normalize_utilization(entry.get("percent"), percent_scale)
    if percent < 0:
      continue
    seen.add((name, kind_raw))
    kind = window_kind(kind_raw, name)
    window = {
      "session": "Session",
      "week": "Weekly",
      "month": "Monthly",
    }.get(kind, "")
    title = (name + " " + window).strip() if window and window.lower() not in name.lower() else name
    out.append(limit_entry(title, percent, normalize_reset_at(entry.get("resets_at")), kind))
  return out


def fetch_limits(token):
  request = urllib.request.Request(
    USAGE_ENDPOINT,
    headers={
      "Authorization": "Bearer " + token,
      "anthropic-beta": "oauth-2025-04-20",
      "Accept": "application/json",
      "User-Agent": USER_AGENT,
    },
  )
  try:
    with urllib.request.urlopen(request, timeout=10) as response:
      payload = json.loads(response.read().decode("utf-8", errors="replace"))
  except urllib.error.HTTPError as error:
    code = getattr(error, "code", 0)
    if code == 401 or code == 403:
      return None, "auth", "Claude Code sign-in expired. Run `claude auth login`."
    if code == 429:
      return None, "error", "Claude usage is rate limited. Try again in a minute."
    return None, "error", "Could not load Claude usage."
  except Exception:
    return None, "error", "Network error while loading Claude usage."

  if not isinstance(payload, dict):
    return None, "error", "Claude usage response was not a JSON object."

  weekly = usage_bucket(payload, "seven_day_oauth_apps") or usage_bucket(payload, "seven_day")
  session = usage_bucket(payload, "five_hour")
  raw = [
    session.get("utilization") if session else None,
    weekly.get("utilization") if weekly else None,
  ]
  entries = payload.get("limits")
  if isinstance(entries, list):
    raw += [entry.get("percent") for entry in entries if isinstance(entry, dict)]
  percent_scale = any(parse_utilization(v) >= 1 for v in raw)

  limits = []
  if session is not None:
    percent = normalize_utilization(session.get("utilization"), percent_scale)
    if percent >= 0:
      limits.append(limit_entry(
        "Session",
        percent,
        normalize_reset_at(session.get("resets_at")),
        "session",
      ))
  if weekly is not None:
    percent = normalize_utilization(weekly.get("utilization"), percent_scale)
    if percent >= 0:
      limits.append(limit_entry(
        "Weekly",
        percent,
        normalize_reset_at(weekly.get("resets_at")),
        "week",
      ))
  limits.extend(scoped_limits(payload, percent_scale))
  if not limits:
    return None, "error", "Claude usage response did not include limits."
  return limits, "ok", ""


def map_omarchy_limits(entries):
  out = []
  if not isinstance(entries, list):
    return out
  for entry in entries:
    if not isinstance(entry, dict):
      continue
    title = str(entry.get("title") or entry.get("label") or "").strip()
    try:
      percent = float(entry.get("percent"))
    except (TypeError, ValueError):
      continue
    if not (percent >= 0):
      continue
    if percent > 1:
      percent = min(1.0, percent / 100.0)
    kind = window_kind("", title)
    reset_iso = normalize_reset_at(entry.get("resetsAt") or entry.get("resetAt"))
    item = limit_entry(title.split("(")[0].strip() or title, percent, reset_iso, kind)
    if title.lower().startswith("session"):
      item["title"] = "Session"
      item["kind"] = "session"
      item["dayCount"] = 0
      item["periodStart"] = period_start_iso(item["resetAt"], SESSION_MS)
    elif title.lower().startswith("weekly") and " " not in title.split("(")[0].strip().lower():
      item["title"] = "Weekly"
      item["kind"] = "week"
      item["dayCount"] = 7
    out.append(item)
  return out


def collect_omarchy_limits():
  binary = shutil.which("omarchy-agent-usage-claude")
  if not binary:
    return None
  try:
    proc = subprocess.run(
      [binary, "--limits-only"],
      capture_output=True,
      text=True,
      timeout=20,
      check=False,
    )
  except Exception:
    return None
  if proc.returncode != 0:
    return None
  try:
    payload = json.loads(proc.stdout)
  except Exception:
    return None
  if not isinstance(payload, dict):
    return None
  limits = map_omarchy_limits(payload.get("limits"))
  if not limits:
    return None
  tier = str(payload.get("tierLabel") or "").strip()
  return {"limits": limits, "tier": tier, "status": str(payload.get("usageStatusText") or "")}


def build_result(oauth, limits, config_dir=None):
  session = next((item for item in limits if item.get("kind") == "session"), None)
  weekly = next((item for item in limits if item.get("kind") == "week" and item.get("title") == "Weekly"), None)
  if weekly is None:
    weekly = next((item for item in limits if item.get("kind") == "week"), None)

  ident = dict(oauth or {})
  profile = load_profile(config_dir or DEFAULT_CONFIG)
  ident["name"] = ident.get("name") or profile.get("name") or ""
  ident["email"] = ident.get("email") or profile.get("email") or ""
  ident["tier"] = ident.get("tier") or profile.get("tier") or "Claude"

  out = empty_result(
    tierLabel=ident.get("tier") or "Claude",
    accountName=str(ident.get("name") or "").strip(),
    accountEmail=str(ident.get("email") or "").strip(),
    limits=limits,
  )
  if session:
    out["rateLimitPercent"] = session["percent"]
    out["rateLimitLabel"] = session["title"]
    out["rateLimitResetAt"] = session["resetAt"]
    out["rateLimitPeriodStart"] = session["periodStart"]
  if weekly:
    out["secondaryRateLimitPercent"] = weekly["percent"]
    out["secondaryRateLimitLabel"] = weekly["title"]
    out["secondaryRateLimitResetAt"] = weekly["resetAt"]
    out["secondaryRateLimitPeriodStart"] = weekly["periodStart"]
  return out


def main(argv=None):
  parser = argparse.ArgumentParser(description="Scan Claude Code rate-limit windows")
  parser.add_argument(
    "--config",
    default=os.environ.get("CLAUDE_CONFIG_DIR", str(DEFAULT_CONFIG)),
    help="Path to Claude Code config dir (default: ~/.claude)",
  )
  parser.add_argument(
    "--probe",
    action="store_true",
    help="Print ready/absent if a Claude OAuth token exists (no usage API)",
  )
  args = parser.parse_args(argv)

  config_dir = expand_path(args.config, DEFAULT_CONFIG)
  oauth = load_oauth(config_dir)
  desktop = None if oauth else load_desktop_history()

  if args.probe:
    print("ready" if (oauth or desktop) else "absent")
    return 0

  if not oauth:
    if desktop and desktop.get("limits"):
      return emit(build_result({"tier": desktop.get("tier") or "Claude"}, desktop["limits"], config_dir))
    return emit(empty_result(
      usageStatusText="Sign in to Claude",
      authHelpText=AUTH_HELP,
    ))

  cached = collect_omarchy_limits()
  if cached and cached.get("limits"):
    oauth = dict(oauth)
    if cached.get("tier"):
      oauth["tier"] = cached["tier"]
    out = build_result(oauth, cached["limits"], config_dir)
    if cached.get("status"):
      out["usageStatusText"] = cached["status"]
    return emit(out)

  if oauth["expires_at"] > 0 and oauth["expires_at"] <= time.time() * 1000:
    return emit(empty_result(
      tierLabel=oauth.get("tier") or "",
      usageStatusText="Sign-in expired",
      authHelpText="Claude Code's saved sign-in expired. Run `claude auth login`.",
    ))

  limits, kind, err = fetch_limits(oauth["token"])
  if limits:
    return emit(build_result(oauth, limits, config_dir))
  desktop = load_desktop_history()
  if desktop and desktop.get("limits"):
    return emit(build_result(oauth, desktop["limits"], config_dir))
  if kind == "auth":
    return emit(empty_result(
      tierLabel=oauth.get("tier") or "",
      usageStatusText="Sign-in expired",
      authHelpText=err or AUTH_HELP,
    ))
  return emit(empty_result(
    tierLabel=oauth.get("tier") or "",
    usageStatusText="Claude limits unavailable",
    authHelpText=err or "Could not load Claude usage.",
  ))


if __name__ == "__main__":
  sys.exit(main())
