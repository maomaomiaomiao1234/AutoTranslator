#!/usr/bin/env python3

from types import SimpleNamespace

from backend.app.mouse_monitor import MouseMonitor


class _MockDelegate:
    def __init__(self):
        self.allow_clipboard_fallback = None

    def on_selection_event(self, allow_clipboard_fallback: bool) -> None:
        self.allow_clipboard_fallback = allow_clipboard_fallback


def _make_monitor(dragged=False):
    delegate = _MockDelegate()
    monitor = MouseMonitor(delegate=delegate)
    monitor._mouse_dragged_since_down = dragged
    monitor._mouse_down_point = (24, 24)
    return monitor, delegate


def test_single_click_does_not_trigger_clipboard_fallback(monkeypatch):
    monitor, delegate = _make_monitor(dragged=False)
    event = SimpleNamespace(click_count=1)

    monkeypatch.setattr(monitor, "_on_mouse_down", lambda e: None)
    import backend.app.mouse_monitor as mm_module
    monkeypatch.setattr(mm_module.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        mm_module.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    monitor._on_mouse_up(event)

    assert delegate.allow_clipboard_fallback is False
    assert monitor._mouse_dragged_since_down is False
    assert monitor._mouse_down_point is None


def test_drag_selection_keeps_clipboard_fallback(monkeypatch):
    monitor, delegate = _make_monitor(dragged=True)
    event = SimpleNamespace(click_count=1)

    import backend.app.mouse_monitor as mm_module
    monkeypatch.setattr(mm_module.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        mm_module.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    monitor._on_mouse_up(event)

    assert delegate.allow_clipboard_fallback is True


def test_double_click_keeps_clipboard_fallback(monkeypatch):
    monitor, delegate = _make_monitor(dragged=False)
    event = SimpleNamespace(click_count=2)

    import backend.app.mouse_monitor as mm_module
    monkeypatch.setattr(mm_module.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        mm_module.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    monitor._on_mouse_up(event)

    assert delegate.allow_clipboard_fallback is True
