# 连续划词偶发不触发：排查与修复

## 现象与原因

用户反馈：网页等应用中连续划词偶尔没有浮窗，再划一次又能触发。以下代码路径都可能丢弃单次取词；不能仅凭这一现象判断为翻译接口失败。

| 触发条件 | 原行为 | 修复 |
| --- | --- | --- |
| 浮窗已显示，或在屏幕边缘划词 | 将 CGEvent 的左上原点坐标直接与 AppKit 的左下原点矩形比较，产生镜像的误拦截区域 | 统一转换后再判断浮窗和系统区域；AX 命中查询仍使用原始 Quartz 坐标 |
| 浮窗已经沉到其他应用后面 | `isVisible` 仍为真，旧矩形继续阻挡前方网页取词 | 检查该位置实际接收点击的窗口；标准与极简模式一致处理 |
| 从浮窗、菜单或 Finder 直接回到网页划词 | mouseDown 时前台应用尚未更新，整个手势被当成旧应用的操作而忽略 | 前台应用过滤延后到 mouseUp 后执行 |
| down/up 有明显位移，但中间 dragged 事件缺失 | 退化为仅 AX 的单击探测；不提供 AX 选区的网页无法使用复制兜底 | 使用 down/up 位移补充识别，仍保留 6 点阈值以过滤点击抖动 |
| 两次复制取词间隔不足 120 ms | 直接返回 nil，用户必须重新划词 | 可取消地等待剩余间隔，再处理最新请求 |
| 旧取词未结束就开始新手势 | 只取消未派发的 work item；已经运行的取词可能继续复制或弹窗 | mouseDown 立即取消旧任务，新任务等待旧剪贴板恢复完成；异步取词后重新核对来源应用 |
| 暂停/恢复或 tap 被系统禁用 | 手势忽略标志残留，或已排队的旧选区仍被派发 | 清理完整手势状态与待处理请求，恢复 tap 时从干净状态开始 |

浮窗命中检查采用 AppKit 的 [windowNumber(at:belowWindowWithWindowNumber:)](https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:))，按鼠标实际命中规则处理遮挡及不接收鼠标的窗口。

## 验证

- 修复前：新增的三个手势回归测试全部失败，分别验证缺失 dragged 事件、停止后的忽略状态残留、tap 禁用后旧请求仍派发。
- 修复后：完整单元测试 74 项通过，包括新增 12 项回归测试。
- 新测试覆盖 100 次快速连续手势仅派发最后一次、普通点击不启用复制、主屏及上方/左侧副屏坐标、连续复制限流、取消与来源切换、原剪贴板恢复。
- 剪贴板测试使用独立命名的测试剪贴板与模拟复制，不发送系统快捷键。
- 这些是自动化代码路径验证，尚未对用户原先发生问题的网页进行长期实测。

测试命令：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project AutoTranslator.xcodeproj -scheme AutoTranslator \
  -destination 'platform=macOS' -only-testing:AutoTranslatorTests \
  -derivedDataPath /private/tmp/AutoTranslatorSelectionTests CODE_SIGNING_ALLOWED=NO
```

## 本地体验复核

退出旧版本后打开 `dist/AutoTranslator-local.app`，在网页中重复划选不同段落、重复同一段文字，以及从浮窗直接回到网页划词。分别确认标准/极简模式下都能触发，普通点击不产生复制；也可移动浮窗后，检查其上下镜像位置的网页文字能否正常取词。
