import logging
import time
from typing import Protocol

import Quartz

logger = logging.getLogger(__name__)


class MouseMonitorDelegate(Protocol):
    """MouseMonitor 回调接口。"""

    def on_selection_event(self, allow_clipboard_fallback: bool) -> None:
        """鼠标松开且判定为选择操作后调用。"""
        ...


class MouseMonitor:
    """封装 CGEventTap 鼠标监听和拖拽检测。"""

    DRAG_THRESHOLD_SQ = 36

    def __init__(self, delegate: MouseMonitorDelegate):
        self.delegate = delegate
        self._mouse_down_point: tuple[float, float] | None = None
        self._mouse_dragged_since_down = False
        self._event_tap = None

    def start(self) -> None:
        mask = (
            Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDragged)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseUp)
        )
        self._event_tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionListenOnly, mask, self._callback, None
        )

        if not self._event_tap:
            logger.error("无法创建 EventTap")
            return

        run_loop_source = Quartz.CFMachPortCreateRunLoopSource(None, self._event_tap, 0)
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), run_loop_source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(self._event_tap, True)

    def _callback(self, proxy, type_, event, refcon):
        if type_ == Quartz.kCGEventLeftMouseDown:
            self._on_mouse_down(event)
        elif type_ == Quartz.kCGEventLeftMouseDragged:
            self._on_mouse_dragged(event)
        elif type_ == Quartz.kCGEventLeftMouseUp:
            self._on_mouse_up(event)
        return event

    def _on_mouse_down(self, event) -> None:
        point = Quartz.CGEventGetLocation(event)
        self._mouse_down_point = (point.x, point.y)
        self._mouse_dragged_since_down = False

    def _on_mouse_dragged(self, event) -> None:
        if self._mouse_down_point is None:
            return

        point = Quartz.CGEventGetLocation(event)
        dx = point.x - self._mouse_down_point[0]
        dy = point.y - self._mouse_down_point[1]
        if (dx * dx) + (dy * dy) >= self.DRAG_THRESHOLD_SQ:
            self._mouse_dragged_since_down = True

    def _on_mouse_up(self, event) -> None:
        click_count = Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGMouseEventClickState
        )
        allow = self._mouse_dragged_since_down or click_count > 1

        self._mouse_down_point = None
        self._mouse_dragged_since_down = False
        time.sleep(0.05)
        self.delegate.on_selection_event(allow)
