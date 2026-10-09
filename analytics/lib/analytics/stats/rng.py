"""Version-stable PCG-XSH-RR 64/32 (O'Neill, 2014), no Python random module."""

import hashlib

_MASK = (1 << 64) - 1


def seed_from(*parts):
    """SHA256 length-framed UTF-8 strings; first/next eight bytes, little endian.

    Lengths are unsigned eight-byte big-endian byte counts, preserving boundaries.
    The resulting pair is PCG's initial state and stream, not an internal state.
    """
    digest = hashlib.sha256()
    for part in parts:
        if not isinstance(part, str):
            raise ValueError("seed parts must be strings")
        encoded = part.encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    value = digest.digest()
    return int.from_bytes(value[:8], "little"), int.from_bytes(value[8:16], "little")


class PCG32:
    """PCG reference initialization with a 64-bit state and stream selector."""

    def __init__(self, state=0, stream=54):
        if any(isinstance(x, bool) or not isinstance(x, int) or not 0 <= x <= _MASK
               for x in (state, stream)):
            raise ValueError("state and stream must be unsigned 64-bit integers")
        self.state = 0
        self.increment = ((stream << 1) | 1) & _MASK
        self.next_u32()
        self.state = (self.state + state) & _MASK
        self.next_u32()

    @classmethod
    def from_parts(cls, *parts):
        """Initialize from the documented SHA256 content seed."""
        return cls(*seed_from(*parts))

    def next_u32(self):
        """Return the next unsigned 32-bit PCG-XSH-RR reference output."""
        old = self.state
        self.state = (old * 6364136223846793005 + self.increment) & _MASK
        shifted = (((old >> 18) ^ old) >> 27) & 0xffffffff
        rotation = old >> 59
        return ((shifted >> rotation) | (shifted << ((-rotation) & 31))) & 0xffffffff

    def uniform(self):
        """Uniform [0,1) with 53 random bits from two draws (27 + 26)."""
        return ((self.next_u32() >> 5) * (1 << 26) + (self.next_u32() >> 6)) / (1 << 53)

    def randbelow(self, n):
        """Unbiased integer in range(n), by rejection sampling, any positive n."""
        if isinstance(n, bool) or not isinstance(n, int) or n <= 0:
            raise ValueError("n must be a positive integer")
        if n <= 1 << 32:
            threshold = (1 << 32) % n
            while True:
                value = self.next_u32()
                if value >= threshold:
                    return value % n
        words = (n.bit_length() + 31) // 32
        ceiling = 1 << (32 * words)
        threshold = ceiling % n
        while True:
            value = 0
            for _ in range(words):
                value = (value << 32) | self.next_u32()
            if value >= threshold:
                return value % n
