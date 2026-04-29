import Quartz
import objc
from Cocoa import NSObject
from Foundation import NSNotificationCenter, NSTimer
from AppKit import (
    NSAnimationContext,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSBezelStyleRegularSquare,
    NSButton,
    NSColor,
    NSEvent,
    NSEventMaskKeyDown,
    NSFloatingWindowLevel,
    NSFont,
    NSGradient,
    NSGraphicsContext,
    NSImage,
    NSImageScaleProportionallyUpOrDown,
    NSImageSymbolConfiguration,
    NSLineBreakByWordWrapping,
    NSMenu,
    NSMenuItem,
    NSPanel,
    NSPasteboard,
    NSPointInRect,
    NSPopUpButton,
    NSScreen,
    NSScrollView,
    NSTextAlignmentCenter,
    NSTextField,
    NSView,
    NSVisualEffectBlendingModeBehindWindow,
    NSVisualEffectMaterialMenu,
    NSVisualEffectStateActive,
    NSVisualEffectView,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)


WINDOW_WIDTH = 448
WINDOW_MIN_HEIGHT = 400
OUTER_PADDING = 14
SECTION_GAP = 11
HEADER_HEIGHT = 38
TOOLBAR_BUTTON_SIZE = 28
BACKEND_BTN_WIDTH = 48
CARD_RADIUS = 20
PANEL_RADIUS = 28
CARD_INSET_X = 16
MAX_CARD_TEXT_HEIGHT = 220
SRC_MAX_CARD_HEIGHT = 290
DEST_MAX_CARD_HEIGHT = 340
MAX_WINDOW_HEIGHT = 760
LANG_BAR_HEIGHT = 42
BODY_FONT_SIZE = 15


def rgb(r, g, b, a=1.0):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(
        r / 255.0, g / 255.0, b / 255.0, a
    )


WINDOW_BG = rgb(0, 0, 0, 0)
PANEL_TOP = rgb(248, 242, 232, 0.96)
PANEL_BOTTOM = rgb(231, 240, 248, 0.94)
PANEL_BORDER = rgb(255, 255, 255, 0.62)
SOURCE_CARD_BG = rgb(255, 255, 255, 0.72)
LANG_BAR_BG = rgb(255, 255, 255, 0.58)
DEST_CARD_BG = rgb(251, 253, 255, 0.76)
SURFACE_BG = rgb(255, 255, 255, 0.74)
SURFACE_BG_SOFT = rgb(255, 255, 255, 0.56)
CARD_BORDER = rgb(255, 255, 255, 0.58)
BUTTON_BORDER = rgb(255, 255, 255, 0.78)
TEXT_PRIMARY = rgb(31, 35, 42)
TEXT_SECONDARY = rgb(103, 111, 123)
TEXT_MUTED = rgb(144, 150, 159)
BLUE_ACCENT = rgb(53, 97, 214)
TEAL_ACCENT = rgb(20, 151, 135)
AMBER_ACCENT = rgb(194, 121, 28)
CHIP_BG = rgb(235, 242, 255, 0.96)
CHIP_BG_ALT = rgb(231, 247, 242, 0.96)
CHIP_BG_WARM = rgb(255, 238, 209, 0.97)
GLOW_WARM = rgb(246, 198, 111, 0.22)
GLOW_COOL = rgb(80, 128, 234, 0.16)
GLOW_MINT = rgb(89, 183, 159, 0.12)


def style_surface(view, background, radius, border=None, shadow=False):
    view.setWantsLayer_(True)
    layer = view.layer()
    layer.setCornerRadius_(radius)
    if shadow:
        layer.setMasksToBounds_(False)
        layer.setShadowColor_(NSColor.blackColor().CGColor())
        layer.setShadowOffset_((0, 8))
        layer.setShadowRadius_(20.0)
        layer.setShadowOpacity_(0.08)
    else:
        layer.setMasksToBounds_(True)
        layer.setShadowOpacity_(0.0)
    layer.setBackgroundColor_(background.CGColor())
    if border is not None:
        layer.setBorderWidth_(1.0)
        layer.setBorderColor_(border.CGColor())
    else:
        layer.setBorderWidth_(0.0)


def style_pill(label, text_color, background, border=None):
    label.setTextColor_(text_color)
    style_surface(label, background, 11, border=border)


def create_label(font_size, color=TEXT_PRIMARY, bold=False, selectable=False, wraps=True):
    label = NSTextField.alloc().init()
    label.setEditable_(False)
    label.setSelectable_(selectable)
    label.setBordered_(False)
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setTextColor_(color)
    label.setFont_(
        NSFont.boldSystemFontOfSize_(font_size)
        if bold
        else NSFont.systemFontOfSize_(font_size)
    )
    label.cell().setWraps_(wraps)
    label.cell().setScrollable_(False)
    label.cell().setLineBreakMode_(NSLineBreakByWordWrapping)
    label.cell().setUsesSingleLineMode_(not wraps)
    return label


def create_pill_label(font_size=11, color=TEXT_SECONDARY, background=CHIP_BG):
    label = create_label(font_size, color=color, bold=True, selectable=False, wraps=False)
    label.setAlignment_(NSTextAlignmentCenter)
    style_pill(label, color, background)
    return label


def apply_symbol(button, symbol_name, fallback, point_size=16, tint=TEXT_SECONDARY):
    image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(symbol_name, None)
    if image is not None:
        config = NSImageSymbolConfiguration.configurationWithPointSize_weight_(
            point_size, 0.25
        )
        image = image.imageWithSymbolConfiguration_(config)
        button.setImage_(image)
        button.setImageScaling_(NSImageScaleProportionallyUpOrDown)
        button.setTitle_("")
        button.setContentTintColor_(tint)
    else:
        button.setImage_(None)
        button.setTitle_(fallback)
        button.setFont_(NSFont.systemFontOfSize_(point_size))


def create_icon_button(
    symbol_name,
    fallback,
    point_size=16,
    tint=TEXT_SECONDARY,
    background=SURFACE_BG,
    size=TOOLBAR_BUTTON_SIZE,
):
    button = NSButton.alloc().init()
    button.setBordered_(False)
    button.setBezelStyle_(NSBezelStyleRegularSquare)
    style_surface(button, background, size / 2, border=BUTTON_BORDER)
    apply_symbol(button, symbol_name, fallback, point_size=point_size, tint=tint)
    return button


def measure_text_height(text, width, font_size, bold=False, minimum=0):
    probe = create_label(font_size, bold=bold, wraps=True)
    probe.setStringValue_(text or "")
    size = probe.cell().cellSizeForBounds_(((0, 0), (width, 10000)))
    return max(minimum, int(size.height) + 2)


def measure_text_width(text, font_size, bold=False):
    probe = create_label(font_size, bold=bold, wraps=False)
    probe.setStringValue_(text or "")
    return int(probe.cell().cellSize().width)


class BorderlessWindow(NSPanel):
    def canBecomeKeyWindow(self):
        return True

    def canBecomeMainWindow(self):
        return True

    def acceptsFirstMouse_(self, event):
        return True

    def mouseDown_(self, event):
        self.performWindowDragWithEvent_(event)

    def keyDown_(self, event):
        if event.keyCode() == 53:
            pass
        else:
            return


class PanelBackgroundView(NSView):
    def isOpaque(self):
        return False

    def mouseDown_(self, event):
        if self.window() is not None:
            self.window().performWindowDragWithEvent_(event)

    def drawRect_(self, rect):
        bounds = Quartz.CGRectInset(self.bounds(), 0.5, 0.5)
        panel_path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            bounds, PANEL_RADIUS, PANEL_RADIUS
        )
        gradient = NSGradient.alloc().initWithStartingColor_endingColor_(
            PANEL_TOP, PANEL_BOTTOM
        )
        gradient.drawInBezierPath_angle_(panel_path, -90.0)

        NSGraphicsContext.saveGraphicsState()
        panel_path.addClip()
        for glow_rect, glow_color in (
            (
                (
                    (bounds.origin.x - 18, bounds.origin.y + bounds.size.height - 126),
                    (190, 190),
                ),
                GLOW_WARM,
            ),
            (
                (
                    (
                        bounds.origin.x + bounds.size.width - 204,
                        bounds.origin.y - 26,
                    ),
                    (230, 230),
                ),
                GLOW_COOL,
            ),
            (
                (
                    (
                        bounds.origin.x + bounds.size.width - 152,
                        bounds.origin.y + bounds.size.height - 178,
                    ),
                    (176, 176),
                ),
                GLOW_MINT,
            ),
        ):
            glow_color.setFill()
            NSBezierPath.bezierPathWithOvalInRect_(glow_rect).fill()
        NSGraphicsContext.restoreGraphicsState()

        PANEL_BORDER.setStroke()
        panel_path.setLineWidth_(1.0)
        panel_path.stroke()


class FloatingWindow(NSObject):
    def init(self):
        self = objc.super(FloatingWindow, self).init()
        if self is None:
            return None

        style_mask = (
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        )
        self.window = BorderlessWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (WINDOW_WIDTH, WINDOW_MIN_HEIGHT)),
            style_mask,
            NSBackingStoreBuffered,
            False,
        )

        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.clearColor())
        self.window.setHasShadow_(True)
        self.window.setReleasedWhenClosed_(False)
        self.window.setMovableByWindowBackground_(True)
        self.window.floating_window = self

        self.vibrancy_view = NSVisualEffectView.alloc().initWithFrame_(
            ((0, 0), (WINDOW_WIDTH, WINDOW_MIN_HEIGHT))
        )
        self.vibrancy_view.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
        self.vibrancy_view.setMaterial_(NSVisualEffectMaterialMenu)
        self.vibrancy_view.setState_(NSVisualEffectStateActive)
        self.vibrancy_view.setWantsLayer_(True)
        self.window.setContentView_(self.vibrancy_view)

        self.root_view = NSView.alloc().initWithFrame_(
            ((0, 0), (WINDOW_WIDTH, WINDOW_MIN_HEIGHT))
        )
        self.vibrancy_view.addSubview_(self.root_view)
        self.background_view = PanelBackgroundView.alloc().initWithFrame_(
            ((0, 0), (WINDOW_WIDTH, WINDOW_MIN_HEIGHT))
        )
        self.root_view.addSubview_(self.background_view)

        self.current_source_text = ""
        self.current_dest_text = ""
        self.backend = "google"
        self.is_pinned = False
        self.delegate = None
        self.saved_origin = None
        self._suppress_auto_pin = False
        self._stream_timer = None

        self.build_toolbar()
        self.build_source_card()
        self.build_language_bar()
        self.build_dest_card()
        self.setup_menu()
        self.setup_key_monitor()
        self.refresh_pin_style()
        self.refresh_action_state()
        self.refresh_source_meta()
        self.set_translation_state("idle")
        self.set_backend_label("google")
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "windowDidMove:", "NSWindowDidMoveNotification", self.window
        )

        return self

    @objc.python_method
    def build_toolbar(self):
        self.pin_btn = create_icon_button(
            "pin.fill", "📌", point_size=12, tint=TEXT_SECONDARY
        )
        self.pin_btn.setTarget_(self)
        self.pin_btn.setAction_("togglePin:")
        self.root_view.addSubview_(self.pin_btn)

        self.header_title_label = create_label(
            16, color=TEXT_PRIMARY, bold=True, selectable=False, wraps=False
        )
        self.header_title_label.setStringValue_("划词翻译")
        self.root_view.addSubview_(self.header_title_label)

        self.header_subtitle_label = create_label(
            11, color=TEXT_SECONDARY, bold=False, selectable=False, wraps=False
        )
        self.header_subtitle_label.setStringValue_("自动检测 → 中文简体 · Google")
        self.root_view.addSubview_(self.header_subtitle_label)

        self.quick_source_copy_btn = create_icon_button(
            "scissors", "✂", point_size=12, tint=TEXT_SECONDARY
        )
        self.quick_source_copy_btn.setTarget_(self)
        self.quick_source_copy_btn.setAction_("copySource:")
        self.root_view.addSubview_(self.quick_source_copy_btn)

        self.quick_dest_copy_btn = create_icon_button(
            "doc.on.doc", "⧉", point_size=12, tint=TEXT_SECONDARY
        )
        self.quick_dest_copy_btn.setTarget_(self)
        self.quick_dest_copy_btn.setAction_("copyDest:")
        self.root_view.addSubview_(self.quick_dest_copy_btn)

        self.backend_btn = NSButton.alloc().init()
        self.backend_btn.setBordered_(False)
        self.backend_btn.setBezelStyle_(NSBezelStyleRegularSquare)
        self.backend_btn.setTitle_("LLM")
        self.backend_btn.setFont_(NSFont.boldSystemFontOfSize_(11))
        self.backend_btn.setTarget_(self)
        self.backend_btn.setAction_("onBackendToggle:")
        style_surface(
            self.backend_btn,
            SURFACE_BG,
            BACKEND_BTN_WIDTH / 2,
            border=BUTTON_BORDER,
        )
        self.root_view.addSubview_(self.backend_btn)

        self.hide_btn = create_icon_button(
            "xmark", "✕", point_size=12, tint=TEXT_SECONDARY
        )
        self.hide_btn.setTarget_(self)
        self.hide_btn.setAction_("hideWindow:")
        self.root_view.addSubview_(self.hide_btn)

    @objc.python_method
    def build_source_card(self):
        self.src_card = NSView.alloc().init()
        style_surface(
            self.src_card,
            SOURCE_CARD_BG,
            CARD_RADIUS,
            border=CARD_BORDER,
            shadow=True,
        )
        self.root_view.addSubview_(self.src_card)

        self.src_title_label = create_label(
            11, color=TEXT_SECONDARY, bold=True, selectable=False, wraps=False
        )
        self.src_title_label.setStringValue_("原文")
        self.src_card.addSubview_(self.src_title_label)

        self.src_meta_chip = create_pill_label(
            font_size=10, color=TEXT_SECONDARY, background=SURFACE_BG_SOFT
        )
        self.src_card.addSubview_(self.src_meta_chip)

        self.src_scroll = NSScrollView.alloc().init()
        self.src_scroll.setHasVerticalScroller_(True)
        self.src_scroll.setAutohidesScrollers_(True)
        self.src_scroll.setBorderType_(0)
        self.src_scroll.setDrawsBackground_(False)
        self.src_card.addSubview_(self.src_scroll)

        self.src_label = create_label(
            BODY_FONT_SIZE, color=TEXT_PRIMARY, bold=False, selectable=True, wraps=True
        )
        self.src_scroll.setDocumentView_(self.src_label)

        self.src_audio_btn = create_icon_button(
            "speaker.wave.2",
            "🔊",
            point_size=11,
            tint=TEXT_MUTED,
            background=SURFACE_BG,
            size=24,
        )
        self.src_audio_btn.setEnabled_(False)
        self.src_audio_btn.setAlphaValue_(0.45)
        self.src_card.addSubview_(self.src_audio_btn)

        self.src_copy_btn = create_icon_button(
            "doc.on.doc",
            "⧉",
            point_size=11,
            tint=TEXT_PRIMARY,
            background=SURFACE_BG,
            size=24,
        )
        self.src_copy_btn.setTarget_(self)
        self.src_copy_btn.setAction_("copySource:")
        self.src_card.addSubview_(self.src_copy_btn)

        self.src_lang_chip = create_pill_label(
            font_size=10, color=BLUE_ACCENT, background=CHIP_BG
        )
        self.src_card.addSubview_(self.src_lang_chip)

    @objc.python_method
    def build_language_bar(self):
        self.lang_bar = NSView.alloc().init()
        style_surface(
            self.lang_bar,
            LANG_BAR_BG,
            CARD_RADIUS,
            border=CARD_BORDER,
            shadow=True,
        )
        self.root_view.addSubview_(self.lang_bar)

        self.src_lang_pop = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            ((0, 0), (80, 26)), False
        )
        self.configure_popup(self.src_lang_pop)
        self.src_lang_pop.setTarget_(self)
        self.src_lang_pop.setAction_("onLangChange:")
        self.lang_bar.addSubview_(self.src_lang_pop)

        self.swap_btn = create_icon_button(
            "arrow.left.arrow.right",
            "⇄",
            point_size=12,
            tint=TEXT_PRIMARY,
            background=SURFACE_BG,
            size=24,
        )
        self.swap_btn.setTarget_(self)
        self.swap_btn.setAction_("swapLanguages:")
        self.lang_bar.addSubview_(self.swap_btn)

        self.dest_lang_pop = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            ((0, 0), (80, 26)), False
        )
        self.configure_popup(self.dest_lang_pop)
        self.dest_lang_pop.setTarget_(self)
        self.dest_lang_pop.setAction_("onLangChange:")
        self.lang_bar.addSubview_(self.dest_lang_pop)

    @objc.python_method
    def build_dest_card(self):
        self.dest_card = NSView.alloc().init()
        style_surface(
            self.dest_card,
            DEST_CARD_BG,
            CARD_RADIUS,
            border=CARD_BORDER,
            shadow=True,
        )
        self.root_view.addSubview_(self.dest_card)

        self.backend_badge = NSView.alloc().init()
        style_surface(self.backend_badge, BLUE_ACCENT, 12)
        self.dest_card.addSubview_(self.backend_badge)

        self.backend_badge_label = create_label(
            10, color=NSColor.whiteColor(), bold=True, selectable=False, wraps=False
        )
        self.backend_badge_label.setAlignment_(NSTextAlignmentCenter)
        self.backend_badge.addSubview_(self.backend_badge_label)

        self.backend_name_label = create_label(
            12, color=TEXT_PRIMARY, bold=True, selectable=False, wraps=False
        )
        self.dest_card.addSubview_(self.backend_name_label)

        self.dest_state_chip = create_pill_label(
            font_size=10, color=TEXT_SECONDARY, background=SURFACE_BG_SOFT
        )
        self.dest_card.addSubview_(self.dest_state_chip)

        self.backend_toggle_btn = create_icon_button(
            "chevron.down",
            "⌄",
            point_size=9,
            tint=TEXT_SECONDARY,
            background=SURFACE_BG,
            size=24,
        )
        self.backend_toggle_btn.setTarget_(self)
        self.backend_toggle_btn.setAction_("onBackendToggle:")
        self.dest_card.addSubview_(self.backend_toggle_btn)

        self.dest_scroll = NSScrollView.alloc().init()
        self.dest_scroll.setHasVerticalScroller_(True)
        self.dest_scroll.setAutohidesScrollers_(True)
        self.dest_scroll.setBorderType_(0)
        self.dest_scroll.setDrawsBackground_(False)
        self.dest_card.addSubview_(self.dest_scroll)

        self.dest_label = create_label(
            BODY_FONT_SIZE, color=TEXT_PRIMARY, bold=False, selectable=True, wraps=True
        )
        self.dest_scroll.setDocumentView_(self.dest_label)

        self.dest_copy_btn = create_icon_button(
            "doc.on.doc",
            "⧉",
            point_size=11,
            tint=TEXT_PRIMARY,
            background=SURFACE_BG,
            size=24,
        )
        self.dest_copy_btn.setTarget_(self)
        self.dest_copy_btn.setAction_("copyDest:")
        self.dest_card.addSubview_(self.dest_copy_btn)

        self.dest_refresh_btn = create_icon_button(
            "arrow.clockwise",
            "↻",
            point_size=11,
            tint=TEXT_PRIMARY,
            background=SURFACE_BG,
            size=24,
        )
        self.dest_refresh_btn.setTarget_(self)
        self.dest_refresh_btn.setAction_("refreshTranslation:")
        self.dest_card.addSubview_(self.dest_refresh_btn)

    @objc.python_method
    def configure_popup(self, popup):
        popup.setBordered_(False)
        popup.setFont_(NSFont.boldSystemFontOfSize_(12))
        popup.setContentTintColor_(TEXT_PRIMARY)
        popup.setWantsLayer_(True)
        popup.layer().setBackgroundColor_(NSColor.clearColor().CGColor())

    @objc.python_method
    def setup_key_monitor(self):
        def handle_event(event):
            if event.keyCode() == 53:
                if self.window.isVisible():
                    mouse_loc = NSEvent.mouseLocation()
                    if NSPointInRect(mouse_loc, self.window.frame()):
                        self.hide()
                        return None
            return event

        NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            NSEventMaskKeyDown, handle_event
        )
        NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSEventMaskKeyDown, handle_event
        )

    @objc.python_method
    def setup_menu(self):
        self.menu = NSMenu.alloc().initWithTitle_("Options")
        close_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "隐藏窗口", "hideWindow:", ""
        )
        close_item.setTarget_(self)
        self.menu.addItem_(close_item)
        self.root_view.setMenu_(self.menu)

    @objc.python_method
    def set_button_enabled(self, button, enabled):
        button.setEnabled_(enabled)
        button.setAlphaValue_(1.0 if enabled else 0.36)

    @objc.python_method
    def refresh_pin_style(self):
        accent = BLUE_ACCENT if self.is_pinned else TEXT_SECONDARY
        background = CHIP_BG if self.is_pinned else SURFACE_BG_SOFT
        style_surface(
            self.pin_btn,
            background,
            TOOLBAR_BUTTON_SIZE / 2,
            border=BUTTON_BORDER,
        )
        apply_symbol(self.pin_btn, "pin.fill", "📌", point_size=12, tint=accent)

    @objc.python_method
    def refresh_action_state(self):
        has_source = bool(self.current_source_text)
        has_dest = bool(self.current_dest_text)
        self.set_button_enabled(self.quick_source_copy_btn, has_source)
        self.set_button_enabled(self.src_copy_btn, has_source)
        self.set_button_enabled(self.quick_dest_copy_btn, has_dest)
        self.set_button_enabled(self.dest_copy_btn, has_dest)
        self.set_button_enabled(self.dest_refresh_btn, has_source)

    @objc.python_method
    def refresh_source_meta(self):
        source_text = self.current_source_text.strip()
        if source_text:
            meta_text = f"{len(source_text)} 字符"
            style_pill(self.src_meta_chip, TEXT_SECONDARY, SURFACE_BG)
        else:
            meta_text = "等待选中"
            style_pill(self.src_meta_chip, TEXT_MUTED, SURFACE_BG_SOFT)
        self.src_meta_chip.setStringValue_(meta_text)

    @objc.python_method
    def refresh_header_status(self):
        src_title = self.src_lang_pop.titleOfSelectedItem() or "自动检测"
        dest_title = self.dest_lang_pop.titleOfSelectedItem() or "中文简体"
        provider = "大模型" if self.backend == "llm" else "Google"
        self.header_subtitle_label.setStringValue_(
            f"{src_title} → {dest_title} · {provider}"
        )

    @objc.python_method
    def set_translation_state(self, state):
        if state == "done":
            text = "已完成"
            text_color = TEAL_ACCENT
            background = CHIP_BG_ALT
        elif state == "loading":
            text = "翻译中"
            text_color = AMBER_ACCENT
            background = CHIP_BG_WARM
        else:
            text = "待翻译"
            text_color = TEXT_MUTED
            background = SURFACE_BG_SOFT
        self.dest_state_chip.setStringValue_(text)
        style_pill(self.dest_state_chip, text_color, background)

    @objc.python_method
    def refresh_language_ui(self):
        src_title = self.src_lang_pop.titleOfSelectedItem() or "自动检测"
        if src_title == "自动检测":
            badge = "自动检测"
            can_swap = False
            style_pill(self.src_lang_chip, TEXT_SECONDARY, SURFACE_BG)
        else:
            badge = src_title
            can_swap = True
            style_pill(self.src_lang_chip, BLUE_ACCENT, CHIP_BG)
        self.src_lang_chip.setStringValue_(badge)
        self.set_button_enabled(self.swap_btn, can_swap)
        self.refresh_header_status()

    @objc.python_method
    def set_languages(self, languages, source, target):
        self.src_lang_pop.removeAllItems()
        self.dest_lang_pop.removeAllItems()

        source_titles = list(languages.keys())
        target_titles = [name for name, code in languages.items() if code != "auto"]

        self.src_lang_pop.addItemsWithTitles_(source_titles)
        self.dest_lang_pop.addItemsWithTitles_(target_titles)

        for name, code in languages.items():
            if code == source:
                self.src_lang_pop.selectItemWithTitle_(name)
            if code == target and code != "auto":
                self.dest_lang_pop.selectItemWithTitle_(name)

        if self.dest_lang_pop.indexOfSelectedItem() < 0 and target_titles:
            self.dest_lang_pop.selectItemWithTitle_(target_titles[0])

        self.refresh_language_ui()

    def onLangChange_(self, sender):
        self.refresh_language_ui()
        if self.delegate:
            src_name = self.src_lang_pop.titleOfSelectedItem()
            dest_name = self.dest_lang_pop.titleOfSelectedItem()
            self.delegate.language_changed(src_name, dest_name)

    def togglePin_(self, sender):
        self.is_pinned = not self.is_pinned
        self.refresh_pin_style()

    def auto_pin(self):
        if not self.is_pinned:
            self.is_pinned = True
            self.refresh_pin_style()

    def windowDidMove_(self, notification):
        if not self._suppress_auto_pin:
            self.auto_pin()

    def onBackendToggle_(self, sender):
        if self.delegate:
            self.delegate.toggle_translator()

    def swapLanguages_(self, sender):
        if self.delegate:
            self.delegate.swap_languages()

    def refreshTranslation_(self, sender):
        if self.delegate:
            self.delegate.retranslate_current()

    def copySource_(self, sender):
        self.copy_text(self.current_source_text)

    def copyDest_(self, sender):
        self.copy_text(self.current_dest_text)

    def hideWindow_(self, sender):
        self.hide()

    @objc.python_method
    def copy_text(self, text):
        if not text:
            return
        pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.declareTypes_owner_(["public.utf8-plain-text"], None)
        pasteboard.setString_forType_(text, "public.utf8-plain-text")

    @objc.python_method
    def set_backend_label(self, backend):
        self.backend = backend
        if backend == "llm":
            accent = TEAL_ACCENT
            badge_text = "AI"
            backend_name = "大模型翻译"
        else:
            accent = BLUE_ACCENT
            badge_text = "G"
            backend_name = "Google 翻译"

        style_surface(self.backend_badge, accent, 12)
        self.backend_badge_label.setStringValue_(badge_text)
        self.backend_name_label.setStringValue_(backend_name)
        self.backend_name_label.setTextColor_(TEXT_PRIMARY)
        self.backend_btn.setTitle_("LLM")
        if backend == "llm":
            self.backend_btn.setContentTintColor_(accent)
            style_surface(
                self.backend_btn,
                rgb(
                    int((accent.redComponent() * 255 + 255) / 2),
                    int((accent.greenComponent() * 255 + 255) / 2),
                    int((accent.blueComponent() * 255 + 255) / 2),
                    0.95,
                ),
                BACKEND_BTN_WIDTH / 2,
                border=BUTTON_BORDER,
            )
        else:
            self.backend_btn.setContentTintColor_(TEXT_SECONDARY)
            style_surface(
                self.backend_btn,
                SURFACE_BG,
                BACKEND_BTN_WIDTH / 2,
                border=BUTTON_BORDER,
            )
        self.refresh_header_status()

    @objc.python_method
    def layout_window(self):
        content_width = WINDOW_WIDTH - (OUTER_PADDING * 2)
        card_inner_width = content_width - (CARD_INSET_X * 2)

        src_text_height = measure_text_height(
            self.current_source_text or " ", card_inner_width, BODY_FONT_SIZE, minimum=48
        )
        dest_display_text = self.current_dest_text or "正在翻译..."
        dest_text_height = measure_text_height(
            dest_display_text, card_inner_width, BODY_FONT_SIZE, minimum=40
        )

        src_visible = min(src_text_height, MAX_CARD_TEXT_HEIGHT)
        dest_visible = min(dest_text_height, MAX_CARD_TEXT_HEIGHT)

        src_card_height = min(SRC_MAX_CARD_HEIGHT, max(118, src_visible + 68))
        lang_bar_height = LANG_BAR_HEIGHT
        dest_card_height = min(DEST_MAX_CARD_HEIGHT, max(132, dest_visible + 82))
        total_height = min(
            MAX_WINDOW_HEIGHT,
            max(
                WINDOW_MIN_HEIGHT,
                int(
                    OUTER_PADDING
                    + HEADER_HEIGHT
                    + SECTION_GAP
                    + src_card_height
                    + SECTION_GAP
                    + lang_bar_height
                    + SECTION_GAP
                    + dest_card_height
                    + OUTER_PADDING
                ),
            ),
        )

        overhead = (
            OUTER_PADDING
            + HEADER_HEIGHT
            + SECTION_GAP
            + SECTION_GAP
            + lang_bar_height
            + SECTION_GAP
            + OUTER_PADDING
        )
        available = total_height - overhead
        if src_card_height + dest_card_height > available:
            src_card_height = max(108, int(available * 7 / 15))
            dest_card_height = max(124, available - src_card_height)

        self.root_view.setFrame_(((0, 0), (WINDOW_WIDTH, total_height)))
        self.vibrancy_view.setFrame_(((0, 0), (WINDOW_WIDTH, total_height)))
        self.background_view.setFrame_(((0, 0), (WINDOW_WIDTH, total_height)))
        self.background_view.setNeedsDisplay_(True)

        header_y = total_height - OUTER_PADDING - HEADER_HEIGHT
        toolbar_y = header_y + (HEADER_HEIGHT - TOOLBAR_BUTTON_SIZE) / 2
        self.pin_btn.setFrame_(
            ((OUTER_PADDING, toolbar_y), (TOOLBAR_BUTTON_SIZE, TOOLBAR_BUTTON_SIZE))
        )

        title_x = OUTER_PADDING + TOOLBAR_BUTTON_SIZE + 10
        title_width = max(120, content_width - 220)
        self.header_title_label.setFrame_(((title_x, header_y + 18), (title_width, 16)))
        self.header_subtitle_label.setFrame_(
            ((title_x, header_y + 2), (title_width + 24, 14))
        )

        right_x = WINDOW_WIDTH - OUTER_PADDING
        for button in (
            self.hide_btn,
            self.backend_btn,
            self.quick_dest_copy_btn,
            self.quick_source_copy_btn,
        ):
            btn_w = BACKEND_BTN_WIDTH if button is self.backend_btn else TOOLBAR_BUTTON_SIZE
            button.setFrame_(((right_x - btn_w, toolbar_y), (btn_w, TOOLBAR_BUTTON_SIZE)))
            right_x -= btn_w + 6

        src_y = header_y - SECTION_GAP - src_card_height
        self.src_card.setFrame_(((OUTER_PADDING, src_y), (content_width, src_card_height)))
        src_visible_h = src_card_height - 82
        self.src_scroll.setFrame_(((CARD_INSET_X, 42), (card_inner_width, src_visible_h)))
        self.src_label.setFrame_(((0, 0), (card_inner_width, src_text_height)))
        self.src_title_label.setFrame_(((CARD_INSET_X, src_card_height - 30), (40, 14)))
        self.src_audio_btn.setFrame_(((CARD_INSET_X, 12), (24, 24)))
        self.src_copy_btn.setFrame_(((CARD_INSET_X + 30, 12), (24, 24)))

        meta_text = self.src_meta_chip.stringValue() or "等待选中"
        meta_width = min(max(measure_text_width(meta_text, 10, bold=True) + 18, 72), 110)
        self.src_meta_chip.setFrame_(
            ((content_width - CARD_INSET_X - meta_width, src_card_height - 34), (meta_width, 20))
        )

        chip_text = self.src_lang_chip.stringValue() or "自动检测"
        chip_width = min(max(measure_text_width(chip_text, 10, bold=True) + 18, 72), 126)
        self.src_lang_chip.setFrame_(
            ((content_width - CARD_INSET_X - chip_width, 14), (chip_width, 20))
        )

        lang_y = src_y - SECTION_GAP - lang_bar_height
        self.lang_bar.setFrame_(((OUTER_PADDING, lang_y), (content_width, lang_bar_height)))
        popup_width = (content_width - 72) / 2
        self.src_lang_pop.setFrame_(((CARD_INSET_X, 8), (popup_width, 24)))
        self.swap_btn.setFrame_((((content_width - 24) / 2, 9), (24, 24)))
        self.dest_lang_pop.setFrame_(
            ((content_width - CARD_INSET_X - popup_width, 8), (popup_width, 24))
        )

        dest_y = lang_y - SECTION_GAP - dest_card_height
        self.dest_card.setFrame_(((OUTER_PADDING, dest_y), (content_width, dest_card_height)))

        dest_visible_h = dest_card_height - 84
        dest_text_y_scroll = 42
        self.dest_scroll.setFrame_(
            ((CARD_INSET_X, dest_text_y_scroll), (card_inner_width, dest_visible_h))
        )
        self.dest_label.setFrame_(((0, 0), (card_inner_width, dest_text_height)))

        provider_y = dest_text_y_scroll + dest_visible_h + 8
        toggle_x = content_width - CARD_INSET_X - 24
        state_text = self.dest_state_chip.stringValue() or "待翻译"
        state_width = min(max(measure_text_width(state_text, 10, bold=True) + 18, 60), 78)
        state_x = toggle_x - 8 - state_width
        self.backend_badge.setFrame_(((CARD_INSET_X, provider_y), (24, 24)))
        self.backend_badge_label.setFrame_(((0, 4), (24, 14)))
        self.backend_name_label.setFrame_(((CARD_INSET_X + 32, provider_y + 4), (state_x - 58, 16)))
        self.dest_state_chip.setFrame_(((state_x, provider_y + 2), (state_width, 20)))
        self.backend_toggle_btn.setFrame_(((toggle_x, provider_y), (24, 24)))
        self.dest_copy_btn.setFrame_(((CARD_INSET_X, 12), (24, 24)))
        self.dest_refresh_btn.setFrame_(((CARD_INSET_X + 30, 12), (24, 24)))

    @objc.python_method
    def show(self, src_text, dest_text=None):
        self._stop_stream()
        was_visible = self.window.isVisible()

        self.current_source_text = src_text or ""
        self.current_dest_text = dest_text or ""

        self.src_label.setStringValue_(self.current_source_text)
        if dest_text:
            self.dest_label.setStringValue_(dest_text)
            self.dest_label.setTextColor_(TEXT_PRIMARY)
            self.set_translation_state("done")
        else:
            self.dest_label.setStringValue_("正在翻译...")
            self.dest_label.setTextColor_(TEXT_MUTED)
            self.set_translation_state("loading")

        self.refresh_source_meta()
        self.refresh_language_ui()
        self.refresh_action_state()
        self.layout_window()

        new_height = self.root_view.frame().size.height
        self._suppress_auto_pin = True

        if was_visible:
            frame = self.window.frame()
            top = frame.origin.y + frame.size.height
            x, y = frame.origin.x, top - new_height

            def resize(ctx):
                ctx.setDuration_(0.18)
                self.window.animator().setFrame_display_(
                    ((x, y), (WINDOW_WIDTH, new_height)), True
                )

            NSAnimationContext.runAnimationGroup_completionHandler_(resize, None)
        else:
            if self.saved_origin is not None:
                x, y = self.saved_origin
            else:
                screen_frame = NSScreen.mainScreen().frame()
                x = (screen_frame.size.width - WINDOW_WIDTH) / 2 + screen_frame.origin.x
                y = (screen_frame.size.height - new_height) / 2 + screen_frame.origin.y

            self.window.setFrame_display_(
                ((x, y), (WINDOW_WIDTH, new_height)), True
            )

            self.window.setAlphaValue_(0.0)
            self.window.makeKeyAndOrderFront_(None)

            def fade_in(ctx):
                ctx.setDuration_(0.22)
                self.window.animator().setAlphaValue_(1.0)

            NSAnimationContext.runAnimationGroup_completionHandler_(fade_in, None)

        self._suppress_auto_pin = False

    @objc.python_method
    def stream_feed(self, text):
        """流式翻译：喂入累积的完整译文，打字机逐字展示。"""
        if not self._stream_timer:
            self._start_stream()
        self._stream_buffer = text

    @objc.python_method
    def stream_finish(self, final_text):
        """流式翻译结束：确保最终文本完整显示并做布局。"""
        self._stream_final = final_text
        self._stream_buffer = final_text
        if self._stream_pos >= len(final_text):
            self._finish_stream()

    @objc.python_method
    def _start_stream(self):
        self._stop_stream()
        self._stream_buffer = ""
        self._stream_pos = 0
        self._stream_final = None
        self.dest_label.setStringValue_("")
        self.dest_label.setTextColor_(TEXT_PRIMARY)
        self.set_translation_state("loading")
        self._stream_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.03, self, "_streamTick:", None, True
        )

    def _streamTick_(self, timer):
        chars_per_tick = 2
        self._stream_pos = min(self._stream_pos + chars_per_tick, len(self._stream_buffer))
        displayed = self._stream_buffer[:self._stream_pos]

        if displayed == self.current_dest_text:
            if self._stream_final is not None and self._stream_pos >= len(self._stream_buffer):
                self._finish_stream()
            return

        self.current_dest_text = displayed
        self.dest_label.setStringValue_(displayed)
        self.refresh_action_state()

        card_inner_width = WINDOW_WIDTH - (OUTER_PADDING * 2) - (CARD_INSET_X * 2)
        full_text_height = measure_text_height(
            displayed, card_inner_width, BODY_FONT_SIZE, minimum=40
        )
        self.dest_label.setFrame_(((0, 0), (card_inner_width, full_text_height)))

        needed_card_height = min(DEST_MAX_CARD_HEIGHT, max(132, full_text_height + 82))
        old_card_height = self.dest_card.frame().size.height
        if int(needed_card_height) > int(old_card_height):
            self.layout_window()
            new_height = self.root_view.frame().size.height
            frame = self.window.frame()
            top = frame.origin.y + frame.size.height
            x, y = frame.origin.x, top - new_height
            self._suppress_auto_pin = True
            self.window.setFrame_display_(((x, y), (WINDOW_WIDTH, new_height)), True)
            self._suppress_auto_pin = False

        if self._stream_final is not None and self._stream_pos >= len(self._stream_buffer):
            self._finish_stream()

    @objc.python_method
    def _stop_stream(self):
        if self._stream_timer:
            self._stream_timer.invalidate()
            self._stream_timer = None
        self._stream_final = None

    @objc.python_method
    def _finish_stream(self):
        self._stop_stream()
        self.current_dest_text = self._stream_buffer
        self.dest_label.setStringValue_(self._stream_buffer)
        self.set_translation_state("done")
        self.refresh_action_state()
        self.layout_window()

        new_height = self.root_view.frame().size.height
        if self.window.isVisible():
            frame = self.window.frame()
            top = frame.origin.y + frame.size.height
            x, y = frame.origin.x, top - new_height
            self._suppress_auto_pin = True

            def resize(ctx):
                ctx.setDuration_(0.15)
                self.window.animator().setFrame_display_(
                    ((x, y), (WINDOW_WIDTH, new_height)), True
                )

            NSAnimationContext.runAnimationGroup_completionHandler_(resize, None)
            self._suppress_auto_pin = False

    @objc.python_method
    def hide(self):
        self._stop_stream()
        if not self.is_pinned:
            frame = self.window.frame()
            self.saved_origin = (frame.origin.x, frame.origin.y)

        def fade_out(ctx):
            ctx.setDuration_(0.12)
            self.window.animator().setAlphaValue_(0.0)

        def on_complete():
            self.window.orderOut_(None)
            self.window.setAlphaValue_(1.0)

        NSAnimationContext.runAnimationGroup_completionHandler_(fade_out, on_complete)
