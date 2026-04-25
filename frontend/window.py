import Quartz
import objc
from Cocoa import NSObject
from AppKit import (
    NSWindow, NSTextField, NSBackingStoreBuffered,
    NSFloatingWindowLevel, NSColor, NSFont,
    NSMenu, NSMenuItem, NSButton, NSPopUpButton,
    NSImage, NSBezelStyleRegularSquare, NSNoBorder,NSView
)


def create_styled_label(font_size=13, color=NSColor.blackColor()):
    label = NSTextField.alloc().init()
    label.setEditable_(False)
    label.setBordered_(False)
    label.setDrawsBackground_(True)
    label.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.96, 1.0))
    label.setTextColor_(color)
    label.setFont_(NSFont.systemFontOfSize_(font_size))
    label.setWantsLayer_(True)
    label.layer().setCornerRadius_(8.0)
    label.layer().setMasksToBounds_(True)
    return label

class FloatingWindow(NSObject):
    def init(self):
        self = objc.super(FloatingWindow, self).init()
        if self is None: return None

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (380, 450)),
            0,
            NSBackingStoreBuffered,
            False
        )

        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(True)
        self.window.setBackgroundColor_(NSColor.whiteColor())
        self.window.setHasShadow_(True)
        self.window.setReleasedWhenClosed_(False)
        self.window.setMovableByWindowBackground_(True)

        # 1. 左上角固定按钮
        self.pin_btn = NSButton.alloc().initWithFrame_(((10, 420), (30, 30)))
        self.pin_btn.setTitle_("📌")
        self.pin_btn.setBezelStyle_(NSBezelStyleRegularSquare)
        self.pin_btn.setBordered_(False)
        self.pin_btn.setTarget_(self)
        self.pin_btn.setAction_("togglePin:")
        self.window.contentView().addSubview_(self.pin_btn)

        # 2. 原文区域
        self.src_label = create_styled_label(font_size=14)
        self.window.contentView().addSubview_(self.src_label)
        
        # 复制按钮 (原文)
        self.src_copy_btn = NSButton.alloc().init()
        self.src_copy_btn.setTitle_("📋")
        self.src_copy_btn.setBezelStyle_(NSBezelStyleRegularSquare)
        self.src_copy_btn.setBordered_(False)
        self.window.contentView().addSubview_(self.src_copy_btn)

        # 3. 中间语言切换条
        self.lang_bar = NSView.alloc().init()
        self.lang_bar.setWantsLayer_(True)
        self.lang_bar.layer().setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.96, 1.0).CGColor())
        self.lang_bar.layer().setCornerRadius_(8.0)
        self.window.contentView().addSubview_(self.lang_bar)

        self.src_lang_pop = NSPopUpButton.alloc().init()
        self.src_lang_pop.setBordered_(False)
        self.lang_bar.addSubview_(self.src_lang_pop)

        self.swap_btn = NSButton.alloc().init()
        self.swap_btn.setTitle_("⇄")
        self.swap_btn.setBezelStyle_(NSBezelStyleRegularSquare)
        self.swap_btn.setBordered_(False)
        self.lang_bar.addSubview_(self.swap_btn)

        self.dest_lang_pop = NSPopUpButton.alloc().init()
        self.dest_lang_pop.setBordered_(False)
        self.lang_bar.addSubview_(self.dest_lang_pop)

        # 4. 译文区域
        self.dest_label = create_styled_label(font_size=15, color=NSColor.blackColor())
        self.window.contentView().addSubview_(self.dest_label)
        
        # 复制按钮 (译文)
        self.dest_copy_btn = NSButton.alloc().init()
        self.dest_copy_btn.setTitle_("📋")
        self.dest_copy_btn.setBezelStyle_(NSBezelStyleRegularSquare)
        self.dest_copy_btn.setBordered_(False)
        self.window.contentView().addSubview_(self.dest_copy_btn)

        self.is_pinned = False
        self.setup_menu()
        self.delegate = None
        
        return self

    @objc.python_method
    def set_languages(self, languages, source, target):
        self.src_lang_pop.removeAllItems()
        self.dest_lang_pop.removeAllItems()
        
        langs = sorted(languages.keys())
        self.src_lang_pop.addItemsWithTitles_(langs)
        self.dest_lang_pop.addItemsWithTitles_(langs)
        
        # 找到对应的全名并选中
        for name, code in languages.items():
            if code == source: self.src_lang_pop.selectItemWithTitle_(name)
            if code == target: self.dest_lang_pop.selectItemWithTitle_(name)
            
        self.src_lang_pop.setTarget_(self)
        self.src_lang_pop.setAction_("onLangChange:")
        self.dest_lang_pop.setTarget_(self)
        self.dest_lang_pop.setAction_("onLangChange:")

    def onLangChange_(self, sender):
        if self.delegate:
            src_name = self.src_lang_pop.titleOfSelectedItem()
            dest_name = self.dest_lang_pop.titleOfSelectedItem()
            self.delegate.language_changed(src_name, dest_name)

    def togglePin_(self, sender):
        self.is_pinned = not self.is_pinned
        self.pin_btn.setAlphaValue_(1.0 if self.is_pinned else 0.4)

    def setup_menu(self):
        self.menu = NSMenu.alloc().initWithTitle_("Options")
        close_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("隐藏窗口", "hideWindow:", "")
        close_item.setTarget_(self)
        self.menu.addItem_(close_item)
        self.window.contentView().setMenu_(self.menu)

    def hideWindow_(self, sender):
        self.window.orderOut_(None)

    @objc.python_method
    def show(self, src_text, dest_text=None):
        self.src_label.setStringValue_(src_text)
        self.dest_label.setStringValue_(dest_text if dest_text else "正在翻译...")

        # 布局计算
        padding = 15
        spacing = 10
        width = 380
        inner_width = width - (padding * 2)

        def get_height(text, w, font_size):
            tmp = NSTextField.alloc().init()
            tmp.setFont_(NSFont.systemFontOfSize_(font_size))
            tmp.setStringValue_(text)
            cell = tmp.cell()
            rect = cell.cellSizeForBounds_(((0, 0), (w - 20, 2000)))
            return max(60, rect.height + 30)

        h1 = get_height(src_text, inner_width, 14)
        h_bar = 40
        h2 = get_height(dest_text if dest_text else "正在翻译...", inner_width, 15)

        total_height = h1 + h_bar + h2 + (spacing * 2) + (padding * 2) + 40 # 40 是顶部留白

        # 设置 Frame (从下往上)
        y = padding
        self.dest_label.setFrame_(((padding, y), (inner_width, h2)))
        self.dest_copy_btn.setFrame_(((padding + 5, y + 5), (25, 25)))
        
        y += h2 + spacing
        self.lang_bar.setFrame_(((padding, y), (inner_width, h_bar)))
        self.src_lang_pop.setFrame_(((10, 5), (130, 30)))
        self.swap_btn.setFrame_(((inner_width/2 - 15, 5), (30, 30)))
        self.dest_lang_pop.setFrame_(((inner_width - 140, 5), (130, 30)))

        y += h_bar + spacing
        self.src_label.setFrame_(((padding, y), (inner_width, h1)))
        self.src_copy_btn.setFrame_(((padding + 5, y + 5), (25, 25)))

        # 窗口位置更新
        if not self.is_pinned:
            loc = Quartz.NSEvent.mouseLocation()
            self.window.setFrame_display_(((loc.x + 10, loc.y - total_height - 10), (width, total_height)), True)
        else:
            f = self.window.frame()
            top = f.origin.y + f.size.height
            self.window.setFrame_display_(((f.origin.x, top - total_height), (width, total_height)), True)
        
        # 按钮位置微调
        self.pin_btn.setFrame_(((10, total_height - 35), (30, 30)))

        self.window.makeKeyAndOrderFront_(None)

    @objc.python_method
    def hide(self):
        self.window.orderOut_(None)
