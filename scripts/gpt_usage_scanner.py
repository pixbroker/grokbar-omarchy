#!/usr/bin/env python3
"""Scan GPT (Codex / ChatGPT) rate-limit windows for the Omarchy bar widget.

Reads the local Codex CLI login (~/.codex/auth.json) and calls ChatGPT's
usage endpoint. Expired OAuth tokens are refreshed via auth.openai.com and
written back atomically. Session, weekly, and extra windows travel in
`limits`. Tokens are never logged or written to scanner JSON.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULT_HOME = Path.home() / ".codex"
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
TOKEN_URL = "https://auth.openai.com/oauth/token"
# Official Codex CLI OAuth client; refresh tokens are minted for this id.
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
USER_AGENT = "grokbar-omarchy/1.6"
AUTH_HELP = "No local Codex session. If you use Codex, run `codex login`."
SESSION_HELP = "Codex session expired. If you use Codex, run `codex login`."
REFRESH_SKEW_SEC = 120

SESSION_MS = 5 * 3600 * 1000
WEEK_MS = 7 * 24 * 3600 * 1000
MONTH_MS = 30 * 24 * 3600 * 1000

_RESOURCE_MARKUP = (
  "<img", "<image", "<object", "<embed", "<iframe", "<frame",
  "<link", "<meta", "<base", "<source", "<svg", "<script", "<style",
)

# Codex CLI display names for ChatGPT plan_type values.
PLAN_LABELS = {
  "free": "Free",
  "go": "Go",
  "plus": "Plus",
  "pro": "Pro",
  "prolite": "Pro Lite",
  "pro_lite": "Pro Lite",
  "team": "Team",
  "self_serve_business_prolite": "Business Pro Lite",
  "self_serve_business_usage_based": "Business",
  "business": "Business",
  "enterprise": "Enterprise",
  "ent26": "Enterprise",
  "edu": "Edu",
  "education": "Edu",
  "edu_plus": "Edu Plus",
  "edu_pro": "Edu Pro",
}


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


def plain_text(value, max_len=128):
  text = str(value or "").replace("\x00", "").strip()
  if not text:
    return ""
  compact = "".join(text.lower().split())
  for tag in _RESOURCE_MARKUP:
    if tag in compact:
      return ""
  if len(text) > max_len:
    return text[:max_len].rstrip()
  return text


def runtime_env(codex_home):
  home = str(Path.home())
  path_parts = [
    os.environ.get("PATH", ""),
    f"{home}/.local/bin",
    f"{home}/.npm-global/bin",
    f"{home}/.local/share/mise/shims",
  ]
  env = os.environ.copy()
  env["PATH"] = os.pathsep.join(part for part in path_parts if part)
  if codex_home:
    env["CODEX_HOME"] = str(codex_home)
  return env


def find_command(name, env):
  return shutil.which(name, path=env.get("PATH"))


def decode_jwt(token):
  text = str(token or "").strip()
  if not text:
    return None
  parts = text.split(".")
  if len(parts) < 2:
    return None
  try:
    pad = "=" * (-len(parts[1]) % 4)
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + pad))
  except Exception:
    return None
  return payload if isinstance(payload, dict) else None


def plan_label(raw):
  text = str(raw or "").strip()
  if not text:
    return ""
  key = text.lower()
  key = key.replace("chatgpt_", "").replace("plan_", "").replace("-", "_")
  if key in PLAN_LABELS:
    return PLAN_LABELS[key]
  cleaned = re.sub(r"[_-]+", " ", text).strip()
  if not cleaned:
    return ""
  return " ".join(part[:1].upper() + part[1:] for part in cleaned.split())


def jwt_identity(payload):
  if not isinstance(payload, dict):
    return "", "", "", ""
  name = str(payload.get("name") or "").strip()
  email = str(payload.get("email") or "").strip()
  plan = str(payload.get("chatgpt_plan_type") or payload.get("planType") or "").strip()
  account_id = ""
  profile = payload.get("https://api.openai.com/profile")
  auth = payload.get("https://api.openai.com/auth")
  if isinstance(profile, dict):
    name = name or str(profile.get("name") or "").strip()
    email = email or str(profile.get("email") or "").strip()
  if isinstance(auth, dict):
    plan = plan or str(auth.get("chatgpt_plan_type") or auth.get("planType") or "").strip()
    name = name or str(auth.get("name") or "").strip()
    email = email or str(auth.get("email") or "").strip()
    account_id = str(
      auth.get("chatgpt_account_id") or auth.get("account_id") or ""
    ).strip()
  return name, email, plan, account_id


def access_needs_refresh(token, skew_sec=REFRESH_SKEW_SEC):
  payload = decode_jwt(token)
  if not payload:
    return True
  exp = payload.get("exp")
  if exp is None or exp == "":
    return False
  try:
    exp_dt = datetime.fromtimestamp(int(float(exp)), timezone.utc)
  except Exception:
    return True
  return exp_dt <= datetime.now(timezone.utc) + timedelta(seconds=skew_sec)


def load_auth(codex_home):
  path = Path(codex_home) / "auth.json"
  try:
    data = json.loads(path.read_text(encoding="utf-8"))
  except Exception:
    return None
  if not isinstance(data, dict):
    return None
  tokens = data.get("tokens") if isinstance(data.get("tokens"), dict) else {}
  access = str(tokens.get("access_token") or "").strip()
  identity = str(tokens.get("id_token") or "").strip()
  refresh = str(tokens.get("refresh_token") or "").strip()
  account_id = str(tokens.get("account_id") or "").strip()
  api_key = str(data.get("OPENAI_API_KEY") or data.get("openai_api_key") or "").strip()
  if not access and not api_key and not refresh:
    return None
  name, email, plan = "", "", ""
  for token in (identity, access):
    extra_name, extra_email, extra_plan, extra_account = jwt_identity(decode_jwt(token))
    name = name or extra_name
    email = email or extra_email
    plan = plan or extra_plan
    account_id = account_id or extra_account
  return {
    "path": path,
    "data": data,
    "access": access,
    "id_token": identity,
    "refresh": refresh,
    "account_id": account_id,
    "api_key": api_key,
    "name": name,
    "email": email,
    "plan": plan_label(plan),
  }


def save_auth(auth):
  """Atomically write refreshed tokens back to auth.json (mode 0600)."""
  path = auth.get("path")
  data = auth.get("data")
  if path is None or not isinstance(data, dict):
    return
  data = dict(data)
  tokens = dict(data.get("tokens") or {})
  if auth.get("access"):
    tokens["access_token"] = auth["access"]
  if auth.get("id_token"):
    tokens["id_token"] = auth["id_token"]
  if auth.get("refresh"):
    tokens["refresh_token"] = auth["refresh"]
  if auth.get("account_id"):
    tokens["account_id"] = auth["account_id"]
  data["tokens"] = tokens
  data["last_refresh"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
  auth["data"] = data
  try:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".auth.", suffix=".tmp", dir=str(path.parent))
    try:
      with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
      os.chmod(tmp, 0o600)
      os.replace(tmp, path)
    except Exception:
      try:
        os.unlink(tmp)
      except OSError:
        pass
      raise
  except Exception as exc:
    sys.stderr.write("grokbar-omarchy: could not write Codex auth.json: %s\n" % exc)


def refresh_token(auth):
  refresh = str(auth.get("refresh") or "").strip()
  if not refresh:
    return False
  body = urllib.parse.urlencode({
    "grant_type": "refresh_token",
    "refresh_token": refresh,
    "client_id": CLIENT_ID,
  }).encode("utf-8")
  request = urllib.request.Request(
    TOKEN_URL,
    data=body,
    headers={
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "application/json",
      "User-Agent": USER_AGENT,
    },
    method="POST",
  )
  try:
    with urllib.request.urlopen(request, timeout=15) as response:
      payload = json.loads(response.read().decode("utf-8", errors="replace"))
  except Exception:
    return False
  if not isinstance(payload, dict):
    return False
  access = str(payload.get("access_token") or "").strip()
  if not access:
    return False
  auth["access"] = access
  if payload.get("id_token"):
    auth["id_token"] = str(payload.get("id_token") or "").strip()
  if payload.get("refresh_token"):
    auth["refresh"] = str(payload.get("refresh_token") or "").strip()
  extra_name, extra_email, extra_plan, extra_account = jwt_identity(decode_jwt(access))
  if extra_name:
    auth["name"] = extra_name
  if extra_email:
    auth["email"] = extra_email
  if extra_plan:
    auth["plan"] = plan_label(extra_plan)
  if extra_account:
    auth["account_id"] = extra_account
  save_auth(auth)
  return True


def ensure_access(auth):
  if auth.get("access") and not access_needs_refresh(auth["access"]):
    return True
  if refresh_token(auth):
    return True
  return bool(auth.get("access"))


def normalize_reset_at(value):
  if value is None:
    return ""
  if isinstance(value, (int, float)):
    ts = float(value)
    if ts < 1e12:
      ts *= 1000
    try:
      return datetime.fromtimestamp(ts / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
      return ""
  raw = str(value).strip()
  if raw == "":
    return ""
  if raw.isdigit():
    return normalize_reset_at(int(raw))
  try:
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
      parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
  except Exception:
    return raw


def parse_window_mins(label, given_mins=0, given_seconds=0):
  try:
    mins = int(given_mins or 0)
  except (TypeError, ValueError):
    mins = 0
  if mins > 0:
    return mins
  try:
    seconds = int(given_seconds or 0)
  except (TypeError, ValueError):
    seconds = 0
  if seconds > 0:
    return max(1, seconds // 60)
  text = str(label or "").lower()
  hours = re.search(r"(\d+)\s*-?\s*h(?:our)?s?\b", text)
  if hours:
    return int(hours.group(1)) * 60
  minutes = re.search(r"(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b", text)
  if minutes:
    return int(minutes.group(1))
  if "week" in text or "7-day" in text or "7 day" in text:
    return 7 * 24 * 60
  if "month" in text or "30-day" in text:
    return 30 * 24 * 60
  if "session" in text:
    return 5 * 60
  return 0


def window_kind(mins, label):
  text = str(label or "").lower()
  if mins == 10080 or "week" in text or "7-day" in text or "7 day" in text:
    return "week"
  if mins >= 20 * 24 * 60 or "month" in text or "30-day" in text:
    return "month"
  if mins and mins <= 12 * 60:
    return "session"
  if "session" in text or "hour" in text:
    return "session"
  if mins:
    return "session" if mins < 24 * 60 else "week"
  return "week"


def window_period_ms(kind, mins):
  if mins > 0:
    return mins * 60 * 1000
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


def window_title(label, kind, mins, prefix=""):
  text = str(label or "").strip()
  lower = text.lower()
  if kind == "week" or "week" in lower or "7-day" in lower:
    # Main ChatGPT/Codex coding pool. ChatGPT.com chat remaining is a
    # different meter and is not this window.
    base = "Codex weekly" if not prefix else "Weekly"
  elif kind == "month" or "month" in lower:
    base = "Monthly"
  elif kind == "session" or "session" in lower:
    if mins and mins != 5 * 60:
      base = (str(mins // 60) + "h") if mins % 60 == 0 else (str(mins) + "m")
    else:
      base = "Session"
  elif text:
    base = text.split("(")[0].strip() or "Limit"
  elif mins:
    base = (str(mins // 60) + "h") if mins % 60 == 0 else (str(mins) + "m")
  else:
    base = "Limit"
  prefix = pretty_limit_name(prefix)
  if prefix and prefix.lower() not in ("codex", "chatgpt", "gpt"):
    if prefix.lower() not in base.lower():
      return (prefix + " " + base).strip()
  return base


def pretty_limit_name(name):
  out = []
  for part in re.split(r"[_-]+", str(name or "").strip()):
    if not part:
      continue
    lower = part.lower()
    if lower == "gpt":
      out.append("GPT")
    elif re.match(r"^\d", part):
      out.append(part)
    else:
      out.append(part[:1].upper() + part[1:])
  return " ".join(out)


def limit_entry(title, percent, reset_iso, kind, mins=0):
  period_ms = window_period_ms(kind, mins)
  return {
    "title": title,
    "percent": percent,
    "resetAt": reset_iso,
    "periodStart": period_start_iso(reset_iso, period_ms),
    "kind": kind,
    "dayCount": 7 if kind == "week" else 0,
  }


def normalize_percent(value):
  try:
    n = float(value)
  except (TypeError, ValueError):
    return -1.0
  if not (n >= 0):
    return -1.0
  if n > 1:
    return min(1.0, n / 100.0)
  return min(1.0, n)


def reset_from_window(window):
  if not isinstance(window, dict):
    return ""
  reset = normalize_reset_at(window.get("reset_at") or window.get("resetsAt") or window.get("resets_at"))
  if reset:
    return reset
  try:
    after = int(window.get("reset_after_seconds") or 0)
  except (TypeError, ValueError):
    after = 0
  if after > 0:
    when = datetime.now(timezone.utc) + timedelta(seconds=after)
    return when.isoformat().replace("+00:00", "Z")
  return ""


def window_from_payload(window, prefix=""):
  if not isinstance(window, dict):
    return None
  used = window.get("used_percent")
  if used is None:
    used = window.get("usedPercent")
  percent = normalize_percent(used)
  if percent < 0:
    return None
  mins = parse_window_mins(
    window.get("limit_name") or prefix,
    window.get("windowDurationMins") or window.get("window_duration_mins") or 0,
    window.get("limit_window_seconds") or window.get("limitWindowSeconds") or 0,
  )
  kind = window_kind(mins, prefix)
  title = window_title("", kind, mins, prefix)
  return limit_entry(title, percent, reset_from_window(window), kind, mins)


def sort_limits(entries):
  order = {"session": 0, "week": 1, "month": 2}
  return sorted(
    entries,
    key=lambda item: (order.get(item.get("kind"), 9), str(item.get("title") or "")),
  )


def is_stale_spark_limit(name):
  text = str(name or "").lower().replace("_", "-")
  if "spark" in text:
    return True
  if "bengalfox" in text:
    return True
  return "5.3" in text and "codex" in text


def collect_wham_windows(payload):
  out = []
  seen = set()

  def add(window, prefix=""):
    entry = window_from_payload(window, prefix)
    if not entry:
      return
    key = (entry["title"], entry["kind"], entry["resetAt"])
    if key in seen:
      return
    seen.add(key)
    out.append(entry)

  rate = payload.get("rate_limit") if isinstance(payload.get("rate_limit"), dict) else {}
  add(rate.get("primary_window"))
  add(rate.get("secondary_window"))
  extra = payload.get("additional_rate_limits")
  if isinstance(extra, list):
    for item in extra:
      if not isinstance(item, dict):
        continue
      name = str(item.get("limit_name") or item.get("metered_feature") or "").strip()
      # Spark was a hardware-gated 5.3 research preview. GPT-6 Astra uses the
      # main plan pool; keep leftover Spark windows off the bar.
      if is_stale_spark_limit(name):
        continue
      nested = item.get("rate_limit") if isinstance(item.get("rate_limit"), dict) else item
      add(nested.get("primary_window"), name)
      add(nested.get("secondary_window"), name)
      if nested.get("used_percent") is not None:
        add(nested, name)
  return out


def fetch_wham_usage(auth):
  token = str(auth.get("access") or "").strip()
  if not token:
    return None, "auth", "Sign-in expired"
  headers = {
    "Authorization": "Bearer " + token,
    "Accept": "application/json",
    "User-Agent": USER_AGENT,
  }
  account_id = str(auth.get("account_id") or "").strip()
  if account_id:
    headers["ChatGPT-Account-Id"] = account_id
  request = urllib.request.Request(USAGE_URL, headers=headers)
  try:
    with urllib.request.urlopen(request, timeout=12) as response:
      payload = json.loads(response.read().decode("utf-8", errors="replace"))
  except urllib.error.HTTPError as error:
    code = getattr(error, "code", 0)
    if code in (401, 403):
      return None, "auth", SESSION_HELP
    if code == 429:
      return None, "error", "GPT usage is rate limited. Try again in a minute."
    return None, "error", "Could not load GPT usage."
  except Exception:
    return None, "error", "Network error while loading GPT usage."
  if not isinstance(payload, dict):
    return None, "error", "GPT usage response was not a JSON object."
  windows = collect_wham_windows(payload)
  plan = plan_label(payload.get("plan_type") or "")
  name = str(payload.get("name") or "").strip()
  email = str(payload.get("email") or "").strip()
  if not windows:
    return {
      "limits": [],
      "tier": plan,
      "name": name,
      "email": email,
    }, "empty", "GPT usage response did not include limits."
  return {
    "limits": windows,
    "tier": plan,
    "name": name,
    "email": email,
  }, "ok", ""


def rpc_request(proc, request_id, method, params=None, timeout=8):
  payload = {"id": request_id, "method": method, "params": params or {}}
  proc.stdin.write(json.dumps(payload) + "\n")
  proc.stdin.flush()
  deadline = time.time() + timeout
  while time.time() < deadline:
    ready, _, _ = select.select([proc.stdout], [], [], 0.25)
    if not ready:
      continue
    line = proc.stdout.readline()
    if not line:
      break
    try:
      message = json.loads(line)
    except Exception:
      continue
    if message.get("id") == request_id:
      return message
  raise TimeoutError(method)


def rpc_window(window, fallback_name=""):
  if not isinstance(window, dict):
    return None
  used = window.get("usedPercent")
  if used is None:
    used = window.get("used_percent")
  percent = normalize_percent(used)
  if percent < 0:
    return None
  mins = parse_window_mins(
    window.get("limitName") or fallback_name,
    window.get("windowDurationMins") or window.get("window_duration_mins") or 0,
    0,
  )
  kind = window_kind(mins, fallback_name)
  title = window_title(str(window.get("limitName") or fallback_name or ""), kind, mins, fallback_name)
  reset_iso = normalize_reset_at(window.get("resetsAt") or window.get("resets_at") or window.get("reset_at"))
  return limit_entry(title, percent, reset_iso, kind, mins)


def collect_rpc_windows(limits_obj):
  out = []
  seen = set()

  def add(window, fallback_name=""):
    entry = rpc_window(window, fallback_name)
    if not entry:
      return
    key = (entry["title"], entry["kind"], entry["resetAt"])
    if key in seen:
      return
    seen.add(key)
    out.append(entry)

  if not isinstance(limits_obj, dict):
    return out
  add(limits_obj.get("primary"))
  add(limits_obj.get("secondary"))
  by_id = limits_obj.get("rateLimitsByLimitId") or limits_obj.get("rate_limits_by_limit_id")
  if isinstance(by_id, dict):
    for limit_id, block in by_id.items():
      if not isinstance(block, dict):
        continue
      name = str(block.get("limitName") or block.get("limit_name") or limit_id or "").strip()
      add(block.get("primary"), name)
      add(block.get("secondary"), name)
      if block.get("usedPercent") is not None or block.get("windowDurationMins") is not None:
        add(block, name)
  return sort_limits(out)


def fetch_codex_rpc(codex_home):
  env = runtime_env(codex_home)
  codex = find_command("codex", env)
  if not codex:
    return None, "missing", "codex not found in PATH"

  try:
    proc = subprocess.Popen(
      [codex, "-s", "read-only", "-a", "on-request", "app-server"],
      stdin=subprocess.PIPE,
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      env=env,
    )
  except Exception:
    return None, "error", "Could not start Codex app-server."

  try:
    rpc_request(proc, 1, "initialize", {"clientInfo": {"name": USER_AGENT, "version": "1.6"}}, timeout=8)
    proc.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
    proc.stdin.flush()
    account_msg = rpc_request(proc, 2, "account/read", timeout=6)
    limits_msg = rpc_request(proc, 3, "account/rateLimits/read", timeout=6)
  except TimeoutError:
    return None, "error", "Codex limits timed out."
  except Exception:
    return None, "error", "Could not load GPT usage."
  finally:
    try:
      proc.terminate()
      proc.wait(timeout=1)
    except Exception:
      try:
        proc.kill()
      except Exception:
        pass

  if isinstance(limits_msg, dict) and limits_msg.get("error"):
    message = str((limits_msg.get("error") or {}).get("message") or "")
    if "401" in message or "expired" in message.lower() or "unauthorized" in message.lower():
      return None, "auth", SESSION_HELP
    return None, "error", "Could not load GPT usage."

  account = ((account_msg or {}).get("result") or {}).get("account") or {}
  limits = ((limits_msg or {}).get("result") or {}).get("rateLimits") or {}
  if not isinstance(account, dict):
    account = {}
  if not isinstance(limits, dict):
    limits = {}
  plan = plan_label(limits.get("planType") or account.get("planType") or account.get("type") or "")
  windows = collect_rpc_windows(limits)
  name = str(account.get("name") or account.get("displayName") or "").strip()
  email = str(account.get("email") or "").strip()
  if not windows:
    return {
      "limits": [],
      "tier": plan,
      "name": name,
      "email": email,
    }, "empty", "Codex usage response did not include limits."
  return {
    "limits": windows,
    "tier": plan,
    "name": name,
    "email": email,
  }, "ok", ""


def map_omarchy_limits(entries):
  out = []
  if not isinstance(entries, list):
    return out
  for entry in entries:
    if not isinstance(entry, dict):
      continue
    title = str(entry.get("title") or entry.get("label") or "").strip()
    percent = normalize_percent(entry.get("percent"))
    if percent < 0:
      continue
    mins = parse_window_mins(title, entry.get("windowDurationMins") or 0, 0)
    kind = window_kind(mins, title)
    reset_iso = normalize_reset_at(entry.get("resetsAt") or entry.get("resetAt"))
    out.append(limit_entry(window_title(title, kind, mins), percent, reset_iso, kind, mins))
  return sort_limits(out)


def collect_omarchy_limits():
  binary = shutil.which("omarchy-agent-usage-codex")
  if not binary:
    return None
  try:
    proc = subprocess.run(
      [binary, "--limits-only"],
      capture_output=True,
      text=True,
      timeout=30,
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
  return {
    "limits": limits,
    "tier": plan_label(payload.get("tierLabel") or ""),
    "status": str(payload.get("usageStatusText") or ""),
    "help": str(payload.get("authHelpText") or ""),
  }


def identity_fields(auth, extra=None):
  extra = extra or {}
  return {
    "tierLabel": plain_text(extra.get("tier") or (auth or {}).get("plan") or "GPT", max_len=80) or "GPT",
    "accountName": plain_text(extra.get("name") or (auth or {}).get("name"), max_len=80),
    "accountEmail": plain_text(extra.get("email") or (auth or {}).get("email"), max_len=128),
  }


def build_result(auth, limits, extra=None):
  extra = extra or {}
  primary = limits[0] if limits else None
  secondary = limits[1] if len(limits) > 1 else None

  out = empty_result(limits=limits, **identity_fields(auth, extra))
  if primary:
    out["rateLimitPercent"] = primary["percent"]
    out["rateLimitLabel"] = primary["title"]
    out["rateLimitResetAt"] = primary["resetAt"]
    out["rateLimitPeriodStart"] = primary["periodStart"]
  if secondary:
    out["secondaryRateLimitPercent"] = secondary["percent"]
    out["secondaryRateLimitLabel"] = secondary["title"]
    out["secondaryRateLimitResetAt"] = secondary["resetAt"]
    out["secondaryRateLimitPeriodStart"] = secondary["periodStart"]
  return out


def expired_result(auth, help_text=None):
  return empty_result(
    **identity_fields(auth),
    usageStatusText="Codex session expired",
    authHelpText=help_text or SESSION_HELP,
  )


def main(argv=None):
  parser = argparse.ArgumentParser(description="Scan GPT (Codex / ChatGPT) rate-limit windows")
  parser.add_argument(
    "--home",
    default=os.environ.get("CODEX_HOME", str(DEFAULT_HOME)),
    help="Path to Codex home (default: ~/.codex)",
  )
  parser.add_argument(
    "--probe",
    action="store_true",
    help="Print ready/absent if a Codex/ChatGPT login exists (no usage API)",
  )
  args = parser.parse_args(argv)

  codex_home = expand_path(args.home, DEFAULT_HOME)
  auth = load_auth(codex_home)

  if args.probe:
    print("ready" if auth else "absent")
    return 0

  if not auth:
    return emit(empty_result(
      usageStatusText="No Codex session",
      authHelpText=AUTH_HELP,
    ))

  if not ensure_access(auth):
    return emit(expired_result(auth, SESSION_HELP))

  usage, kind, err = fetch_wham_usage(auth)
  if kind == "auth":
    if refresh_token(auth):
      usage, kind, err = fetch_wham_usage(auth)
    if kind == "auth":
      return emit(expired_result(auth, err or SESSION_HELP))
  if kind == "ok" and usage and usage.get("limits"):
    return emit(build_result(auth, usage["limits"], usage))

  rpc, rpc_kind, rpc_err = fetch_codex_rpc(codex_home)
  if rpc_kind == "ok" and rpc and rpc.get("limits"):
    return emit(build_result(auth, rpc["limits"], rpc))
  if rpc_kind == "auth":
    return emit(expired_result(auth, rpc_err or SESSION_HELP))

  cached = collect_omarchy_limits()
  if cached and cached.get("limits"):
    out = build_result(auth, cached["limits"], {"tier": cached.get("tier")})
    if cached.get("status"):
      out["usageStatusText"] = cached["status"]
    return emit(out)

  if kind == "empty" and usage:
    return emit(empty_result(
      **identity_fields(auth, usage),
      usageStatusText="GPT limits unavailable",
      authHelpText=err or "Could not load GPT usage.",
    ))
  return emit(empty_result(
    **identity_fields(auth),
    usageStatusText="GPT limits unavailable",
    authHelpText=err or rpc_err or "Could not load GPT usage.",
  ))


if __name__ == "__main__":
  sys.exit(main())
