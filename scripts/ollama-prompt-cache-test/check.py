"""Checks prompt_cache on the variants run.sh created (pc-<runner>-<budget>).

For each variant, two conversations take turns on the model's one slot:
A, then B (which pushes A out of the slot), then A again. A's second turn
can only reuse its prompt if the prompt cache kept it, which ollama reports
as prompt_eval_cached_count. Also checks the flag each runner was started
with, and that changing prompt_cache in a request reloads the model.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

HOST = "http://" + os.environ["OLLAMA_HOST"]
# About 14.5K tokens for A and 23.6K for B on Qwen3; the conversations
# differ from the first token.
DOC = "\n".join(f"Line {i}: the quick brown fox jumps over the lazy dog {i * 7919 % 10007}." for i in range(700))

failures = []


def chat(model, messages, options=None):
    body = {"model": model, "messages": messages, "stream": False, "think": False,
            "options": {"num_predict": 16, "temperature": 0, **(options or {})}}
    req = urllib.request.Request(HOST + "/api/chat", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.load(r)


def runner_flag():
    """The prompt cache flag on the running runner: (flag, value) or None."""
    out = subprocess.run(["ps", "-axww", "-o", "args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "llama-server" in line or " runner --model" in line:
            args = line.split()
            for flag in ("--cache-ram", "--prompt-cache"):
                if flag in args:
                    return flag, args[args.index(flag) + 1]
            return "none", None
    return None


def check(name, ok, detail):
    print(f"   {'PASS' if ok else 'FAIL'}  {name}: {detail}")
    if not ok:
        failures.append(name)


def turns(model, options=None):
    a = [{"role": "user", "content": "Conversation A. Summarize this list.\n" + DOC}]
    b = [{"role": "user", "content": "Conversation B. Count the foxes.\n" + DOC[::-1]}]
    r = chat(model, a, options)
    a += [r["message"], {"role": "user", "content": "And the last line?"}]
    chat(model, b, options)
    start = time.monotonic()
    r2 = chat(model, a, options)
    # Wall time too: prompt_eval_duration leaves out work the runner does
    # before it starts on the prompt, like evicting cache entries.
    return (r2["prompt_eval_count"], r2.get("prompt_eval_cached_count", 0),
            r2["prompt_eval_duration"] / 1e9, time.monotonic() - start)


for runner, flag in (("gguf", "--cache-ram"), ("mlx", "--prompt-cache")):
    print(f"-- {runner} ({flag})")
    for budget in ("unset", "0", "2048"):
        model = f"pc-{runner}-{budget}"
        total, cached, secs, wall = turns(model)
        f = runner_flag()
        want = ("none", None) if budget == "unset" else (flag, budget)
        check(f"{model} flag", f == want, f"started with {f}, want {want}")
        frac = cached / total if total else 0
        if budget == "0":
            check(f"{model} cache", frac < 0.5, f"A's 2nd turn reused {cached}/{total} tokens (prompt {secs:.2f}s, request {wall:.2f}s); want little")
        else:
            check(f"{model} cache", frac > 0.9, f"A's 2nd turn reused {cached}/{total} tokens (prompt {secs:.2f}s, request {wall:.2f}s); want nearly all")
    # A request with a different prompt_cache must restart the runner with it.
    model = f"pc-{runner}-0"
    chat(model, [{"role": "user", "content": "hi"}], {"prompt_cache": 1024})
    f = runner_flag()
    check(f"{model} reload", f == (flag, "1024"), f"after a request with prompt_cache 1024: {f}")

print()
print("All checks passed." if not failures else f"{len(failures)} failed: {', '.join(failures)}")
print(f"Server log: {sys.argv[1]}")
sys.exit(1 if failures else 0)
