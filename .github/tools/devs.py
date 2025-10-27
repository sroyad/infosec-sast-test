#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

DEFAULT_BASE = os.environ.get("DEVSAI_BASE_URL", "https://devs.ai").rstrip("/")
API_VERSION = "1"
CONFIG_DIR = Path.home() / ".devscli"
CONFIG_FILE = CONFIG_DIR / "config.json"

# ---------------------------
# Helpers
# ---------------------------

def require_api_key():
    key = os.environ.get("DEVSAI_API_KEY")
    if not key:
        err = (
            "ERROR: Set DEVSAI_API_KEY environment variable with your devs.ai secret key.\n"
            "Example:\n"
            "  export DEVSAI_API_KEY='sk_xxx...'\n"
        )
        print(err, file=sys.stderr)
        sys.exit(1)
    return key

def headers(api_key, accept="application/json"):
    # Devs.ai expects Bearer token in X-Authorization
    return {
        "Accept": accept,
        "Content-Type": "application/json",
        "X-AppDirect-Api-Version": API_VERSION,
        "X-Authorization": f"Bearer {api_key}",
        "User-Agent": "devs-cli/2.2 (+python-requests)"
    }

def load_config():
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_config(cfg):
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        print(f"(warn) could not save config: {e}", file=sys.stderr)

def debug_print(debug, msg):
    if debug:
        print(f"[DEBUG] {msg}", file=sys.stderr)

# ---------------------------
# API calls
# ---------------------------

def list_ais(base, api_key, debug=False):
    url = f"{base}/api/v1/me/ai?scope=OWNED"
    debug_print(debug, f"GET {url}")
    r = requests.get(url, headers=headers(api_key))
    debug_print(debug, f"-> {r.status_code} {r.text[:300]}")
    if r.status_code != 200:
        raise RuntimeError(f"List AIs failed ({r.status_code}): {r.text}")
    data = r.json()
    if isinstance(data, dict) and "data" in data:
        return data["data"]
    return data

def create_ai(base, api_key, name="My Devs AI", desc="Assistant created from CLI", model_id="gpt-4o-mini", debug=False):
    url = f"{base}/api/v1/ai"
    payload = {
        "name": name,
        "description": desc,
        "instructions": "You are helpful, secure, and concise.",
        "modelId": model_id,
        "visibility": "PRIVATE"
    }
    body = json.dumps(payload)
    debug_print(debug, f"POST {url} body={body}")
    r = requests.post(url, headers=headers(api_key), data=body)
    debug_print(debug, f"-> {r.status_code} {r.text[:500]}")
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Create AI failed ({r.status_code}): {r.text}")
    return r.json()

def approve_ai(base, api_key, ai_id, debug=False):
    url = f"{base}/api/v1/ai/{ai_id}/approve"
    debug_print(debug, f"PUT {url}")
    r = requests.put(url, headers=headers(api_key))
    debug_print(debug, f"-> {r.status_code} {r.text[:300]}")
    if r.status_code != 200:
        print(f"(warn) Approve AI returned {r.status_code}: {r.text}", file=sys.stderr)
    return True

def create_chat_session(base, api_key, ai_id, name=None, debug=False):
    url = f"{base}/api/v1/ai/{ai_id}/chats"
    payload = {}
    if name:
        payload["name"] = name
    body = json.dumps(payload)
    debug_print(debug, f"POST {url} body={body}")
    r = requests.post(url, headers=headers(api_key), data=body)
    debug_print(debug, f"-> {r.status_code} {r.text[:500]}")
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Create chat failed ({r.status_code}): {r.text}")
    data = r.json()
    if isinstance(data, dict) and "id" in data:
        return data
    if isinstance(data, dict) and "data" in data and isinstance(data["data"], dict) and "id" in data["data"]:
        return data["data"]
    return data

def reset_chat(base, api_key, chat_id, debug=False):
    url = f"{base}/api/v1/chats/{chat_id}/reset"
    debug_print(debug, f"PUT {url}")
    r = requests.put(url, headers=headers(api_key))
    debug_print(debug, f"-> {r.status_code} {r.text[:300]}")
    return r.status_code == 200

# --- UPDATED: robust SSE consumer that prints only assistant text ---
def stream_chat_message(base, api_key, chat_id, prompt, debug=False):
    """
    POST /api/v1/chats/{chatId}
    Body: {"date": "ISO", "prompt": "text"}
    Response: SSE (text/event-stream) with JSON events that can arrive concatenated.
    Only prints assistant-visible text (e.g., event.content.text).
    """
    import json
    from json import JSONDecoder

    url = f"{base}/api/v1/chats/{chat_id}"
    body = {
        "date": datetime.now(timezone.utc).isoformat(),
        "prompt": prompt
    }
    body_json = json.dumps(body)
    debug_print(debug, f"POST {url} (SSE) body={body_json}")

    dec = JSONDecoder()

    with requests.post(
        url,
        headers=headers(api_key, accept="text/event-stream"),
        data=body_json,
        stream=True,
        timeout=None
    ) as r:
        if r.status_code != 200:
            raise RuntimeError(f"Send message failed ({r.status_code}): {r.text}")

        assistant_buffer = []
        pending = ""  # holds partial/concatenated JSON after 'data:'

        for raw in r.iter_lines(decode_unicode=True):
            if not raw:
                continue
            if not raw.startswith("data:"):
                # ignore comments/other SSE fields
                continue

            data = raw[5:].strip()
            if data == "[DONE]":
                break

            # Accumulate and try to peel off one or more JSON objects
            pending += data
            while True:
                try:
                    obj, next_idx = dec.raw_decode(pending)
                    pending = pending[next_idx:].lstrip()
                except json.JSONDecodeError:
                    # Incomplete JSON; wait for next line
                    break

                # Parse event
                token = None
                if isinstance(obj, dict):
                    etype = obj.get("type")

                    # Ignore non-content events
                    if etype in ("message.created", "message.complete", "metadata", "stats"):
                        continue

                    # Primary format: {"type":"message.delta","content":{"type":"text","text":"..."}}
                    content = obj.get("content")
                    if isinstance(content, dict) and content.get("type") == "text":
                        token = content.get("text")
                    elif isinstance(content, list):
                        token = "".join(
                            c.get("text", "")
                            for c in content
                            if isinstance(c, dict) and c.get("type") == "text"
                        )

                    # Fallbacks some streams use
                    if not token and isinstance(obj.get("value"), str):
                        token = obj["value"]
                    if not token and isinstance(obj.get("delta"), str):
                        token = obj["delta"]

                # Last-resort: only print if it's plain text
                if not token and isinstance(obj, str):
                    token = obj

                if token:
                    assistant_buffer.append(token)
                    print(token, end="", flush=True)

        print("")  # newline after stream ends
        return "".join(assistant_buffer)

# ---------------------------
# AI Selection (with config)
# ---------------------------

def choose_ai_interactive(ais):
    print("Available AIs:")
    for i, ai in enumerate(ais, 1):
        print(f"{i}. {ai.get('name')}  ({ai.get('id')})")
    choice = input("Select AI number (Enter for 1): ").strip()
    try:
        idx = int(choice) - 1 if choice else 0
    except ValueError:
        idx = 0
    return ais[max(0, min(idx, len(ais)-1))]

def resolve_ai(base, api_key, args, cfg, debug=False):
    # 1) Use cached AI if present (unless overridden)
    last_ai_id = cfg.get("last_ai_id")
    if last_ai_id and not args.ignore_cache:
        print(f"Using cached AI id: {last_ai_id}")
        return {"id": last_ai_id, "name": cfg.get("last_ai_name", "(cached)")}

    # 2) List AIs
    ais = []
    try:
        ais = list_ais(base, api_key, debug=debug)
    except Exception as e:
        print(f"Could not list AIs: {e}")

    if ais:
        if len(ais) == 1 and not args.pick:
            ai = ais[0]
            print(f"Using your existing AI: {ai['name']} (id={ai['id']})")
            return ai
        if args.pick or len(ais) > 1:
            ai = choose_ai_interactive(ais)
            print(f"Selected: {ai['name']} ({ai['id']})")
            return ai

    # 3) None exist — create unless disabled
    if args.no_create:
        print("No AIs found and --no-create is set. Exiting.")
        sys.exit(1)

    print("No AIs found on your account. Creating one ...")
    ai = create_ai(
        base,
        api_key,
        name=args.ai_name or "My Devs AI",
        desc="Assistant created from devs_cli",
        model_id=args.model_id,
        debug=debug
    )
    ai_id = ai.get("id")
    ai_name = ai.get("name", "My Devs AI")
    print(f"Created new AI: {ai_name} (id={ai_id})")
    return ai

# ---------------------------
# Main
# ---------------------------

def main():
    p = argparse.ArgumentParser(description="Fully automated CLI chat for devs.ai")
    p.add_argument("--base-url", default=DEFAULT_BASE, help="Base URL (default: https://devs.ai)")
    p.add_argument("--name", default=None, help="Optional name for the chat session.")
    p.add_argument("--approve", action="store_true", help="Approve the AI before chatting.")
    p.add_argument("--one", default=None, help="Send a single prompt and exit.")
    p.add_argument("--model-id", default="gpt-4o-mini", help="Model for new AI creation (default: gpt-4o-mini).")
    p.add_argument("--ai-name", default=None, help="Name for new AI if created automatically.")
    p.add_argument("--no-create", action="store_true", help="Do not auto-create AI if none exist.")
    p.add_argument("--pick", action="store_true", help="Force interactive selection if multiple AIs exist.")
    p.add_argument("--ignore-cache", action="store_true", help="Ignore cached AI id in ~/.devscli/config.json")
    p.add_argument("--debug", action="store_true", help="Verbose debug logs for API calls.")
    args = p.parse_args()

    api_key = require_api_key()
    base = args.base_url.rstrip("/")

    cfg = load_config()

    # Resolve AI (cached -> list -> create)
    ai = resolve_ai(base, api_key, args, cfg, debug=args.debug)
    ai_id = ai.get("id")
    if not ai_id:
        print("No AI ID resolved. Exiting.", file=sys.stderr)
        sys.exit(1)

    # Save cache ASAP
    cfg["last_ai_id"] = ai_id
    cfg["last_ai_name"] = ai.get("name", "Unnamed AI")
    save_config(cfg)

    # Approve if requested
    if args.approve:
        print(f"Approving AI {ai_id} ...")
        approve_ai(base, api_key, ai_id, debug=args.debug)
        print("AI approved.")

    # Create chat session
    session = create_chat_session(base, api_key, ai_id, name=args.name, debug=args.debug)
    chat_id = session.get("id")
    if not chat_id:
        print(f"ERROR: No chat_id in response: {session}", file=sys.stderr)
        sys.exit(1)
    print(f"Chat session created: {chat_id}")

    # Single prompt mode
    if args.one:
        stream_chat_message(base, api_key, chat_id, args.one, debug=args.debug)
        return

    # REPL mode
    print("\nChat started. Type messages, /exit to quit, /reset to reset.\n")
    while True:
        try:
            user = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            break
        if not user:
            continue
        if user.lower() in ("/exit", "/quit"):
            break
        if user.lower() == "/reset":
            ok = reset_chat(base, api_key, chat_id, debug=args.debug)
            print("(session reset)" if ok else "(reset failed)")
            continue
        try:
            stream_chat_message(base, api_key, chat_id, user, debug=args.debug)
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            time.sleep(0.5)

if __name__ == "__main__":
    main()

