#!/usr/bin/env python3
"""Drive an interactive claude TUI session in a pty to trigger statusline updates."""
import os, pty, select, sys, time

DUMP = "/tmp/statusline-exp/dump.jsonl"
LOG = "/tmp/statusline-exp/tui.log"

pid, fd = pty.fork()
if pid == 0:
    os.chdir("/tmp/statusline-exp")
    os.execvp("claude", ["claude", "--model", "haiku"])

log = open(LOG, "wb")
start = time.time()
sent = {}

def send(key, s, at):
    if key not in sent and time.time() - start > at:
        os.write(fd, s.encode())
        sent[key] = True

try:
    while time.time() - start < 150:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            log.write(data)
            log.flush()
        # 6s: accept possible trust dialog; 12s: send prompt
        send("trust", "\r", 6)
        send("prompt", "hi, reply with one word\r", 12)
        # exit once dump contains rate_limits (or at 70s regardless)
        done = False
        if os.path.exists(DUMP):
            with open(DUMP) as f:
                if "rate_limits" in f.read():
                    done = True
        if done or time.time() - start > 120:
            send("exit", "/exit\r", 0)
            if "exit" in sent:
                time.sleep(3)
                break
finally:
    log.close()
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
print("driver done")
