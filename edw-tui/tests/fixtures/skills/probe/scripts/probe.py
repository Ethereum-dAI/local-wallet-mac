"""One script, several probes; the invoked tool's `mode` argument picks one."""

import os
import socket
import time

import edw_skill

tool, args, context = edw_skill.invoke()
mode = args.get("mode")

if mode == "echo":
    edw_skill.result({"args": args, "chain_id": context.get("chain_id")})
elif mode == "net":
    try:
        socket.create_connection(("1.1.1.1", 443), timeout=2)
        edw_skill.result({"connected": True})
    except OSError as error:
        edw_skill.result({"connected": False, "error": str(error)})
elif mode == "env":
    edw_skill.result({"env": dict(os.environ)})
elif mode == "files":
    paths = args.get("paths") or []
    readable = {p: os.path.exists(p) for p in paths + ["/skill/SKILL.md"]}
    home_entries = os.listdir("/home") if os.path.isdir("/home") else []
    try:
        open("/skill/new.txt", "w").write("x")
        skill_writable = True
    except OSError:
        skill_writable = False
    try:
        open("/tmp/ok.txt", "w").write("x")
        tmp_writable = True
    except OSError:
        tmp_writable = False
    edw_skill.result({"exists": readable, "home_entries": home_entries, "skill_writable": skill_writable, "tmp_writable": tmp_writable})
elif mode == "sleep":
    time.sleep(60)
elif mode == "flood":
    while True:
        print("x" * 65536, flush=True)
elif mode == "host":
    body = edw_skill.http_get("https://yields.llama.fi/pools")
    edw_skill.result({"body": body})
elif mode == "refused":
    try:
        edw_skill.http_get("https://evil.example/")
        edw_skill.result({"refused": False})
    except edw_skill.HostError as error:
        edw_skill.result({"refused": True, "error": str(error)})
elif mode == "plan":
    edw_skill.plan([{"approve": {"token": "usdc", "spender": "pool", "amount": "1"}}])
else:
    edw_skill.fail(f"unknown mode {mode!r}")
