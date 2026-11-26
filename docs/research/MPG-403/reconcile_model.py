#!/usr/bin/env python3
"""Executable model of the MPG-403 reconciliation rules (stdlib only).

Run: python3 -I docs/research/MPG-403/reconcile_model.py
Exits non-zero if an invariant or a worked-table row fails.
"""
import itertools
import random
from dataclasses import dataclass
from typing import Optional

SKEW_MS = 60_000
RANK = {"human": 2, "executor": 1, "default": 0}


@dataclass(frozen=True)
class Change:
    id: str
    wall: int
    ctr: int
    origin: str
    slot: str          # human | executor | default
    field: str         # "pause" or any value field such as "order_key"
    value: object      # bool for pause
    force: bool = False
    reason: str = ""
    supersedes: Optional[str] = None


def sort_key(c):
    # A1: on an exact (wall, ctr) tie a pause sorts last, so it wins the tie.
    pause_rank = 1 if (c.field == "pause" and c.value is True) else 0
    return (c.wall, c.ctr, pause_rank, c.origin, c.id)


def valid(c):
    # A2: the default slot (daemon) never writes pause.
    return not (c.slot == "default" and c.field == "pause")


def fold(changes):
    """Fold a change set (dupes by id collapse, order irrelevant) into registers."""
    regs = {}
    for c in sorted({c.id: c for c in changes}.values(), key=sort_key):
        if not valid(c):
            continue
        s = regs.setdefault(c.field, {"human": None, "executor": None, "default": None})
        if c.field == "pause" and c.slot == "human" and c.value is False:
            for k in s:
                s[k] = None            # rule 5: human unpause clears every slot
        elif c.slot == "executor" and c.force and c.reason:
            h = s["human"]
            if h is not None and c.supersedes == h.id:
                s["human"] = None      # rule 3: takeover, only of the current human change
        s[c.slot] = c
    return regs


def effective(regs, field):
    s = regs.get(field)
    if not s:
        return None
    if field == "pause":
        return any(c is not None and c.value is True for c in s.values())
    for slot in ("human", "executor", "default"):
        if s[slot] is not None:
            return s[slot].value
    return None


def winner(changes, field):
    s = fold(changes).get(field)
    if not s:
        return None
    if field == "pause":
        paused = [c for c in s.values() if c and c.value is True]
        return max(paused, key=sort_key).id if paused else max((c for c in s.values() if c), key=lambda c: RANK[c.slot]).id
    return max((c for c in s.values() if c), key=lambda c: RANK[c.slot]).id


def apply_with_hold(changes, now):
    """Rule 6: hold changes more than SKEW_MS ahead of local time."""
    return [c for c in changes if c.wall <= now + SKEW_MS]


class Gateway:
    """Invariant 3: remote apply never reaches the outbox."""
    def __init__(self, name):
        self.name, self.log, self.outbox = name, {}, []

    def author(self, c):
        self.log[c.id] = c
        self.outbox.append(c.id)

    def apply_remote(self, c):
        self.log[c.id] = c

    def state(self):
        return fold(self.log.values())


# ---------------------------------------------------------------- invariants
def random_set(rng, n):
    cs, humans = [], []
    for i in range(n):
        slot = rng.choice(["human", "executor", "default", "human"])
        field = rng.choice(["pause", "order_key"])
        wall, ctr = rng.randint(1, 4), rng.randint(0, 1)   # tiny range forces ties
        value = rng.choice([True, False]) if field == "pause" else rng.choice("abc")
        force, reason, sup = False, "", None
        if slot == "executor" and rng.random() < .6:
            force, reason = True, rng.choice(["", "why"])
            pool = [h.id for h in humans if h.field == field]
            sup = rng.choice(pool + ["ghost"]) if pool else "ghost"
        c = Change(f"c{i}", wall, ctr, rng.choice("ABC"), slot, field, value, force, reason, sup)
        cs.append(c)
        if slot == "human":
            humans.append(c)
    return cs


def snapshot(regs):
    return {f: {k: (v.id if v else None) for k, v in s.items()} for f, s in regs.items()}


def check_invariants(seed=403, sets=300):
    rng = random.Random(seed)
    perms = 0
    for _ in range(sets):
        cs = random_set(rng, rng.randint(2, 6))
        base = snapshot(fold(cs))
        # I1: every permutation, with duplicate deliveries, folds to the same state.
        for p in itertools.permutations(cs):
            assert snapshot(fold(list(p) + list(p[:2]))) == base, ("I1", p)
            perms += 1
        # I1 (network): three gateways receive in different orders, incrementally.
        gws = [Gateway(n) for n in "XYZ"]
        for g in gws:
            order = cs[:]
            rng.shuffle(order)
            for c in order:
                g.apply_remote(c)
        assert len({str(snapshot(g.state())) for g in gws}) == 1, "I1 gateways"
        # I2: a daemon (default slot) change never displaces a human or executor value.
        for field in ("pause", "order_key"):
            before = effective(fold(cs), field)
            d = Change("daemon", rng.randint(1, 5), 0, "D", "default", field,
                       rng.choice([True, False]) if field == "pause" else "z")
            after = effective(fold(cs + [d]), field)
            regs = fold(cs).get(field, {})
            if any(regs.get(s) for s in ("human", "executor")):
                assert after == before, ("I2", field, before, after)
    # I3
    g = Gateway("A")
    g.author(Change("l1", 1, 0, "A", "human", "order_key", "a"))
    n = len(g.outbox)
    g.apply_remote(Change("r1", 2, 0, "B", "executor", "order_key", "b"))
    g.apply_remote(Change("r1", 2, 0, "B", "executor", "order_key", "b"))
    assert len(g.outbox) == n == 1, "I3"
    return perms


# ---------------------------------------------------------------- worked table
def H(i, w, v, f="order_key", o="A", c=0): return Change(i, w, c, o, "human", f, v)
def E(i, w, v, f="order_key", o="B", sup=None, force=False, r="", c=0): return Change(i, w, c, o, "executor", f, v, force, r, sup)
def D(i, w, v, f="order_key", o="D", c=0): return Change(i, w, c, o, "default", f, v)


def table():
    P = "pause"
    rows = [
        ("1", "Human pin and non-forced Executor edit, Executor is later", [H("h", 10, "a"), E("e", 20, "b")], "order_key", "a"),
        ("2", "Human H1, forced Executor E naming H1, human H2 (all in order)",
         [H("h1", 10, "a"), E("e", 20, "b", sup="h1", force=True, r="blocked"), H("h2", 30, "c")], "order_key", "c"),
        ("3", "Forced Executor E names H1 but H2 is already current",
         [H("h1", 10, "a"), H("h2", 20, "c"), E("e", 30, "b", sup="h1", force=True, r="x")], "order_key", "c"),
        ("4", "Forced Executor E names the current human change",
         [H("h1", 10, "a"), E("e", 20, "b", sup="h1", force=True, r="x")], "order_key", "b"),
        ("5", "Forced Executor without a reason",
         [H("h1", 10, "a"), E("e", 20, "b", sup="h1", force=True, r="")], "order_key", "a"),
        ("6", "Late offline human edit (clock 15) arrives after takeover E at 20 (named h1)",
         [H("h1", 10, "a"), E("e", 20, "b", sup="h1", force=True, r="x"), H("late", 15, "d", o="C")], "order_key", "d"),
        ("7", "Executor clock 2 h slow: forced E stamped before the human change it names",
         [E("e", 5, "b", sup="h1", force=True, r="x"), H("h1", 10, "a")], "order_key", "a"),
        ("8", "Duplicate delivery of every change, reversed order",
         [H("h", 10, "a"), H("h", 10, "a"), E("e", 20, "b"), E("e", 20, "b")], "order_key", "a"),
        ("9", "Human unpause, then Executor pause",
         [H("h", 10, False, P), E("e", 20, True, P)], P, True),
        ("10", "Executor pause, then human unpause",
         [E("e", 10, True, P), H("h", 20, False, P)], P, False),
        ("11", "Exact HLC tie: human unpause vs Executor pause",
         [H("h", 10, False, P, o="Z"), E("e", 10, True, P, o="A")], P, True),
        ("12", "Daemon writes default after human pin",
         [H("h", 10, "a"), D("d", 99, "z")], "order_key", "a"),
        ("13", "Daemon pause against a human unpause",
         [H("h", 10, False, P), D("d", 20, True, P)], P, False),
        ("14", "Two humans on two gateways, same HLC wall and counter (origin breaks tie)",
         [H("a1", 10, "a", o="A"), H("b1", 10, "b", o="B")], "order_key", "b"),
    ]
    out = []
    for num, label, cs, field, expect in rows:
        got = effective(fold(cs), field)
        assert got == expect, (num, label, got, expect)
        assert effective(fold(list(reversed(cs))), field) == expect, (num, "order")
        out.append((num, label, got))
    # Row 15: skew hold, applied to the set a gateway holds at a given local time.
    far = H("far", 10 + 90_000, "f", o="C")
    near = H("h0", 10, "a")
    held = apply_with_hold([near, far], now=10)
    assert effective(fold(held), "order_key") == "a"
    assert effective(fold(apply_with_hold([near, far], now=10 + 40_000)), "order_key") == "f"
    out.append(("15", "Human change 90 s ahead of local time, then clock passes it", "a, then f"))
    return out


if __name__ == "__main__":
    n = check_invariants()
    rows = table()
    for r in rows:
        print(*r, sep=" | ")
    print(f"OK: {n} permutations, {len(rows)} worked rows")
