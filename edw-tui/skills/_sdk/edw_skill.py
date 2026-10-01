"""The edw-tui skill protocol, for scripts. Standard library only.

A script reads one `invoke` line, may ask the harness for data, and ends with exactly one of
`result(...)`, `plan(...)` or `fail(...)`. The container has no network: every HTTP request and
chain read goes through `http_get`, `call` and friends, which the harness serves (and limits to
the hosts the skill declared).
"""

import json
import sys

_next_id = 0


class HostError(Exception):
    """The harness refused or could not complete a host call."""


def _send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _ask(message):
    global _next_id
    _next_id += 1
    message = dict(message, id=_next_id)
    _send(message)
    line = sys.stdin.readline()
    if not line:
        raise HostError("the harness closed the connection")
    reply = json.loads(line)
    if not reply.get("ok"):
        raise HostError(reply.get("error", "host call failed"))
    return reply


def invoke():
    """(tool name, arguments, context). Context has chain_id, me, network, contracts, tokens."""
    message = json.loads(sys.stdin.readline())
    return message["tool"], message.get("args") or {}, message.get("context") or {}


def http_get(url, allow_status=(200,)):
    """The response body as text. Raises HostError for a refused host or an unexpected status."""
    reply = _ask({"type": "http_get", "url": url})
    if reply["status"] not in allow_status:
        raise HostError(f"{url} answered HTTP {reply['status']}")
    return reply["body"]


def http_get_status(url):
    """(status, body) without raising on a non-200 status."""
    reply = _ask({"type": "http_get", "url": url})
    return reply["status"], reply["body"]


def http_post(url, body):
    reply = _ask({"type": "http_post", "url": url, "body": body})
    return reply["status"], reply["body"]


def call(to, function, args=()):
    """Decoded outputs of a view call, e.g.
    call(token, "function balanceOf(address) view returns (uint256)", [me]) -> ["1000000"]."""
    return _ask({"type": "call", "to": to, "function": function, "args": list(args)})["result"]


def eth_call(to, data, block="latest"):
    return _ask({"type": "eth_call", "to": to, "data": data, "block": block})["result"]


def get_balance(address):
    """Wei, as an int."""
    return int(_ask({"type": "eth_getBalance", "address": address})["result"], 16)


def block_number():
    return int(_ask({"type": "eth_blockNumber"})["result"], 16)


def result(value):
    _send({"type": "result", "value": value})
    sys.exit(0)


def plan(steps):
    _send({"type": "plan", "plan": {"steps": steps}})
    sys.exit(0)


def fail(message):
    _send({"type": "error", "message": message})
    sys.exit(0)
