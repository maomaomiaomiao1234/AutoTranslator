#!/usr/bin/env python3

from types import SimpleNamespace

from backend.app import main as app_main


def make_dummy(captured, dragged=False):
    def get_selected_text(*, allow_clipboard_fallback=False):
        captured["allow_clipboard_fallback"] = allow_clipboard_fallback
        return None

    return SimpleNamespace(
        _mouse_dragged_since_down=dragged,
        _mouse_down_point=(24, 24),
        get_selected_text=get_selected_text,
    )


def test_single_click_does_not_trigger_clipboard_fallback(monkeypatch):
    captured = {}
    dummy = make_dummy(captured, dragged=False)
    event = SimpleNamespace(click_count=1)

    monkeypatch.setattr(app_main.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        app_main.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    app_main.AutoTranslator.on_mouse_up(dummy, event=event)

    assert captured["allow_clipboard_fallback"] is False
    assert dummy._mouse_dragged_since_down is False
    assert dummy._mouse_down_point is None


def test_drag_selection_keeps_clipboard_fallback(monkeypatch):
    captured = {}
    dummy = make_dummy(captured, dragged=True)
    event = SimpleNamespace(click_count=1)

    monkeypatch.setattr(app_main.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        app_main.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    app_main.AutoTranslator.on_mouse_up(dummy, event=event)

    assert captured["allow_clipboard_fallback"] is True


def test_double_click_keeps_clipboard_fallback(monkeypatch):
    captured = {}
    dummy = make_dummy(captured, dragged=False)
    event = SimpleNamespace(click_count=2)

    monkeypatch.setattr(app_main.time, "sleep", lambda _: None)
    monkeypatch.setattr(
        app_main.Quartz,
        "CGEventGetIntegerValueField",
        lambda event, field: event.click_count,
    )

    app_main.AutoTranslator.on_mouse_up(dummy, event=event)

    assert captured["allow_clipboard_fallback"] is True
