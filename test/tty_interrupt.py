"""Ctrl-C at the `hsctl login` prompt must leave terminal echo ON.

Runs hsctl on a real pseudo-terminal, waits for the prompt (by which point hsctl
has turned echo off), sends ^C, then reads the terminal's ECHO flag back.
Usage: tty_interrupt.py SHELL HSCTL   -> exit 0 on pass, 1 on fail.
"""
import os
import pty
import select
import sys
import termios
import time

shell, hsctl = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
# A fresh pty's line discipline is not guaranteed to be a normal interactive
# terminal; set the bits that make ^C mean SIGINT and echo meaningful.
attrs = termios.tcgetattr(slave)
attrs[3] |= termios.ISIG | termios.ICANON | termios.ECHO
attrs[6][termios.VINTR] = b"\x03"
termios.tcsetattr(slave, termios.TCSANOW, attrs)
pid = os.fork()
if pid == 0:
    os.setsid()
    os.close(master)
    import fcntl
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)  # make it the controlling tty so ^C sends SIGINT
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.execv(shell, [shell, hsctl, "login"])

os.close(slave)
buf, deadline = b"", time.time() + 5
while b"API key" not in buf and time.time() < deadline:
    if select.select([master], [], [], 0.2)[0]:
        buf += os.read(master, 1024)
if b"API key" not in buf:
    print(f"never saw the prompt: {buf!r}")
    sys.exit(1)

def echo_on():
    return bool(termios.tcgetattr(master)[3] & termios.ECHO)

time.sleep(0.3)
during = echo_on()
os.write(master, b"\x03")
# Never hang the suite: give the child 5s to die from the ^C.
deadline, status = time.time() + 5, None
while time.time() < deadline:
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
    if select.select([master], [], [], 0.1)[0]:
        try:
            buf += os.read(master, 1024)
        except OSError:
            pass
if status is None:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    print(f"child ignored ^C (still running after 5s); echo_on={echo_on()} out={buf[-200:]!r}")
    sys.exit(1)
after = echo_on()
code = os.waitstatus_to_exitcode(status)
print(f"echo during prompt={during} after ^C={after} exit={code}")
sys.exit(0 if (not during and after and code != 0) else 1)
