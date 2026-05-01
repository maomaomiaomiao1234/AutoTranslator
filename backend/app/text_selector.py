import logging
import time

from Cocoa import NSWorkspace
from AppKit import NSPasteboard
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    kAXSelectedTextAttribute,
    kAXFocusedUIElementAttribute,
)

import Quartz

logger = logging.getLogger(__name__)


class TextSelector:
    """文本选择器：Accessibility API + 剪贴板回退。"""

    def __init__(self, copy_interval: float = 0.4):
        self.last_copy_time: float = 0.0
        self.copy_interval: float = copy_interval

    def get_selected_text(self, allow_clipboard_fallback: bool = False,
                          previous_text: str = "") -> str | None:
        front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if not front_app:
            return None
        pid = front_app.processIdentifier()
        try:
            app_ref = AXUIElementCreateApplication(pid)
            focused, err = AXUIElementCopyAttributeValue(app_ref, kAXFocusedUIElementAttribute, None)
            if err == 0 and focused:
                selected, err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute, None)
                if err == 0 and selected and selected.strip():
                    return selected.strip()
        except Exception:
            logger.debug("Accessibility API 获取选中文本失败，回退到剪贴板", exc_info=True)

        if not allow_clipboard_fallback:
            return None
        return self._get_by_clipboard(previous_text)

    def _get_by_clipboard(self, previous_text: str) -> str | None:
        now = time.time()
        if now - self.last_copy_time < self.copy_interval:
            return None
        self.last_copy_time = now

        pb = NSPasteboard.generalPasteboard()
        old_text = pb.stringForType_("public.utf8-plain-text")
        old_count = pb.changeCount()
        self._simulate_cmd_c()

        new_text = None
        for _ in range(20):
            time.sleep(0.01)
            if pb.changeCount() != old_count:
                new_text = pb.stringForType_("public.utf8-plain-text")
                break

        if old_text is not None:
            pb.clearContents()
            pb.declareTypes_owner_(["public.utf8-plain-text", "org.nspasteboard.TransientType"], None)
            pb.setString_forType_(old_text, "public.utf8-plain-text")

        if new_text:
            new_text = new_text.strip()
            return new_text if new_text and new_text != previous_text else None
        return None

    @staticmethod
    def _simulate_cmd_c() -> None:
        event_down = Quartz.CGEventCreateKeyboardEvent(None, 8, True)
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
        event_up = Quartz.CGEventCreateKeyboardEvent(None, 8, False)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)
