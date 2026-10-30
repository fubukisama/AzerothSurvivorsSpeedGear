"""Pure-Python model of the Lua -> config -> native timing boundary.

This models the source's one-scaled-second config quiet period, real-time
heartbeats, 100ms native polling and eight-real-second watchdog. It does not run
the game or establish that an actual client uses these timings in every scene.

The old 3s/file-only strategy is an expected RED baseline: the test asserts its
watchdog oscillation exists. The current 5s heartbeat plus immediate console
delivery must avoid that oscillation, with delayed file copies deduplicated.
"""
from dataclasses import dataclass, field
import unittest


@dataclass(frozen=True)
class Command:
    sequence: int
    emitted_ms: int
    speed100: int


@dataclass
class Result:
    events: list = field(default_factory=list)
    watchdog_ms: list = field(default_factory=list)
    accepted_fast: int = 0
    accepted_file: int = 0
    ignored_file_duplicates: int = 0
    file_writes: int = 0
    final_speed100: int = 100


def simulate(*, heartbeat_seconds=5, speed100=25, fast=True,
             duration_seconds=30, file_delay_ms=0):
    """Simulate one live, single-player session, using integer clock units."""
    if not 25 <= speed100 <= 1000:
        raise ValueError("speed must be in the supported 0.25x..10x range")
    if heartbeat_seconds <= 0 or duration_seconds < 0 or file_delay_ms < 0:
        raise ValueError("invalid model duration")
    result = Result()
    current_speed100 = 100
    virtual_units = 0  # one millisecond at 1x is 100 units
    last_change_units = 0
    dirty = False
    sequence = last_sequence = 0
    last_accepted_ms = None
    pending_command = None
    pending_writes = []
    current_file = None
    observed_file_sequence = 0
    heartbeat_ms = heartbeat_seconds * 1000

    def accept(command, now_ms, source):
        nonlocal current_speed100, last_sequence, last_accepted_ms
        # Both transports share sequence state. A delayed file echo must neither
        # reapply an old request nor extend the watchdog's heartbeat deadline.
        if command.sequence <= last_sequence:
            if source == "file":
                result.ignored_file_duplicates += 1
            return
        if now_ms - command.emitted_ms > 8000:
            return
        last_sequence = command.sequence
        last_accepted_ms = now_ms
        current_speed100 = command.speed100
        if source == "fast":
            result.accepted_fast += 1
        else:
            result.accepted_file += 1
        result.events.append((now_ms, source, current_speed100))

    # 10ms frames, with 100ms polling. Scaled Instant advances continuously when
    # speed changes, rather than resetting its epoch at the transition.
    for now_ms in range(0, duration_seconds * 1000 + 1, 10):
        if now_ms:
            virtual_units += 10 * current_speed100
        if now_ms % heartbeat_ms == 0:
            sequence += 1
            pending_command = Command(sequence, now_ms, speed100)
            dirty = True
            last_change_units = virtual_units
            if fast:
                accept(pending_command, now_ms, "fast")
        if dirty and virtual_units - last_change_units >= 1000 * 100:
            dirty = False
            result.file_writes += 1
            pending_writes.append((now_ms + file_delay_ms, pending_command))
        while pending_writes and pending_writes[0][0] <= now_ms:
            _, current_file = pending_writes.pop(0)
        if now_ms % 100 == 0:
            if current_file and current_file.sequence != observed_file_sequence:
                observed_file_sequence = current_file.sequence
                accept(current_file, now_ms, "file")
            if last_accepted_ms is not None and now_ms - last_accepted_ms > 8000:
                current_speed100 = 100
                last_accepted_ms = None
                result.watchdog_ms.append(now_ms)
                result.events.append((now_ms, "watchdog", 100))
    result.final_speed100 = current_speed100
    return result


class DebounceTests(unittest.TestCase):
    def test_expected_red_old_three_second_file_only_watchdogs(self):
        baseline = simulate(heartbeat_seconds=3, fast=False)
        self.assertGreaterEqual(len(baseline.watchdog_ms), 2)
        self.assertEqual(baseline.events[0], (1000, "file", 25))
        self.assertTrue(any(source == "file" and at > baseline.watchdog_ms[0]
                            for at, source, _ in baseline.events))

    def test_current_five_second_fast_bridge_does_not_starve(self):
        current = simulate()
        self.assertEqual(current.watchdog_ms, [])
        self.assertEqual(current.final_speed100, 25)
        self.assertEqual(current.accepted_fast, 7)  # 0,5,...,30 real seconds
        self.assertEqual(current.accepted_file, 0)
        self.assertGreater(current.ignored_file_duplicates, 0)

    def test_five_second_file_fallback_has_a_quiet_window(self):
        fallback = simulate(fast=False)
        self.assertEqual(fallback.watchdog_ms, [])
        self.assertGreater(fallback.file_writes, 0)
        self.assertEqual(fallback.final_speed100, 25)

    def test_current_fast_bridge_covers_supported_rates(self):
        for speed in (25, 50, 100, 200, 300, 500, 1000):
            with self.subTest(speed100=speed):
                current = simulate(speed100=speed, duration_seconds=60)
                self.assertEqual(current.watchdog_ms, [])
                self.assertEqual(current.final_speed100, speed)

    def test_delayed_fallback_cannot_reapply_older_commands(self):
        for delay in (100, 900, 2000, 6000):
            with self.subTest(file_delay_ms=delay):
                current = simulate(file_delay_ms=delay, duration_seconds=60)
                self.assertEqual(current.watchdog_ms, [])
                self.assertEqual(current.accepted_file, 0)
                self.assertGreater(current.ignored_file_duplicates, 0)

    def test_fast_delivery_does_not_wait_for_the_file(self):
        current = simulate(duration_seconds=2, file_delay_ms=2000)
        self.assertEqual(current.events, [(0, "fast", 25)])
        self.assertEqual(current.file_writes, 0)
        self.assertEqual(current.final_speed100, 25)

    def test_model_rejects_unsupported_rate(self):
        with self.assertRaises(ValueError):
            simulate(speed100=0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
