import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum HistoryScope: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        }
    }
}

struct TranslationHistoryView: View {
    @ObservedObject var store: TranslationHistoryStore

    @State private var searchText = ""
    @State private var scope: HistoryScope = .all
    @State private var selectedID: UUID?
    @State private var showsClearConfirmation = false
    @State private var showsExportSheet = false
    @State private var transferAlert: HistoryTransferAlert?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppUI.cardBorder)
                .frame(height: 1)
            HStack(spacing: 0) {
                historyList
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 390)

                Rectangle()
                    .fill(AppUI.cardBorder)
                    .frame(width: 1)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(AppUI.panelBottom)
        .onAppear {
            refreshQuery()
            selectFirstVisibleEntryIfNeeded()
        }
        .onChange(of: searchText) { _ in
            refreshQuery()
        }
        .onChange(of: scope) { _ in
            refreshQuery()
        }
        .onChange(of: store.entries.map(\.id)) { _ in
            selectFirstVisibleEntryIfNeeded()
        }
        .alert("清空非收藏历史？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                store.clearNonFavorites()
            }
        } message: {
            Text("收藏内容会保留，此操作无法撤销。")
        }
        .alert(transferAlert?.title ?? "", isPresented: transferAlertIsPresented) {
            Button("好", role: .cancel) {
                transferAlert = nil
            }
        } message: {
            Text(transferAlert?.message ?? "")
        }
        .sheet(isPresented: $showsExportSheet) {
            HistoryExportSheet(
                totalCount: store.totalEntryCount,
                favoriteCount: store.favoriteEntryCount,
                onConfirm: { favoritesOnly, format in
                    showsExportSheet = false
                    // 先让 sheet 收起，再弹模态保存面板，避免两者叠在一起。
                    DispatchQueue.main.async {
                        exportEntries(favoritesOnly: favoritesOnly, format: format)
                    }
                },
                onCancel: { showsExportSheet = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: AppUI.Space.l) {
            SymbolBadge(
                symbol: "clock.arrow.circlepath",
                tint: AppUI.accent,
                background: AppUI.activeToolbar,
                size: 40
            )

            VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                Text("翻译历史")
                    .font(.system(size: AppUI.FontSize.display, weight: .bold, design: .serif))
                    .foregroundStyle(AppUI.textPrimary)
                Text("本地保存 · \(store.totalEntryCount) 条记录 · \(store.favoriteEntryCount) 条收藏")
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
            }

            Spacer(minLength: AppUI.Space.m)

            searchField
                .frame(width: 260)

            Picker("", selection: $scope) {
                ForEach(HistoryScope.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)

            Button {
                showsExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 32))
            .disabled(store.totalEntryCount == 0)
            .help("导出历史记录")

            Button {
                importEntries()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 32))
            .help("导入历史记录")

            Button {
                showsClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 32))
            .disabled(store.totalEntryCount == store.favoriteEntryCount)
            .help("清空非收藏历史")
        }
        .padding(.horizontal, AppUI.Space.xxl)
        .padding(.vertical, AppUI.Space.l)
        .background(AppUI.surface)
    }

    private var searchField: some View {
        HStack(spacing: AppUI.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppUI.textMuted)
            TextField("搜索原文或译文", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppUI.textMuted)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, AppUI.Space.m)
        .frame(height: 34)
        .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                historyEmptyState
            } else {
                List(store.entries, selection: $selectedID) { entry in
                    HistoryEntryRow(
                        entry: entry,
                        onToggleFavorite: { store.toggleFavorite(id: entry.id) }
                    )
                    .tag(entry.id)
                    .contextMenu {
                        Button(entry.isFavorite ? "取消收藏" : "收藏") {
                            store.toggleFavorite(id: entry.id)
                        }
                        Button("复制原文") {
                            copyToPasteboard(entry.sourceText)
                        }
                        Button("复制译文") {
                            copyToPasteboard(entry.translatedText)
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            store.delete(id: entry.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(AppUI.surfaceSoft)
            }

            if store.pageCount > 1 {
                Rectangle()
                    .fill(AppUI.cardBorder)
                    .frame(height: 1)
                paginationBar
            }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: AppUI.Space.s) {
            Button {
                store.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!store.canGoToPreviousPage)
            .help("上一页")

            Spacer(minLength: AppUI.Space.xs)
            Text("第 \(store.currentPage + 1) / \(store.pageCount) 页 · \(store.filteredEntryCount) 条")
                .font(.system(size: AppUI.FontSize.micro, weight: .medium))
                .foregroundStyle(AppUI.textMuted)
                .lineLimit(1)
            Spacer(minLength: AppUI.Space.xs)

            Button {
                store.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!store.canGoToNextPage)
            .help("下一页")
        }
        .padding(.horizontal, AppUI.Space.m)
        .frame(height: 36)
        .background(AppUI.surface)
    }

    private var historyEmptyState: some View {
        VStack(spacing: AppUI.Space.l) {
            Image(systemName: scope == .favorites ? "star" : "clock.badge.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppUI.textMuted)
            VStack(spacing: AppUI.Space.xs) {
                Text(emptyStateTitle)
                    .font(.system(size: AppUI.FontSize.section, weight: .semibold))
                    .foregroundStyle(AppUI.textPrimary)
                Text(emptyStateMessage)
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(AppUI.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppUI.surfaceSoft)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedEntry {
            HistoryEntryDetail(
                entry: selectedEntry,
                onToggleFavorite: { store.toggleFavorite(id: selectedEntry.id) },
                onCopySource: { copyToPasteboard(selectedEntry.sourceText) },
                onCopyTranslation: { copyToPasteboard(selectedEntry.translatedText) },
                onDelete: { store.delete(id: selectedEntry.id) }
            )
        } else {
            VStack(spacing: AppUI.Space.m) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppUI.textMuted)
                Text("选择一条记录查看完整内容")
                    .font(.system(size: AppUI.FontSize.base, weight: .medium))
                    .foregroundStyle(AppUI.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEntry: TranslationHistoryEntry? {
        guard let selectedID else { return nil }
        return store.entries.first { $0.id == selectedID }
    }

    private var emptyStateTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有匹配结果"
        }
        return scope == .favorites ? "还没有收藏" : "还没有翻译历史"
    }

    private var emptyStateMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "尝试缩短关键词，或切换到全部记录。"
        }
        return scope == .favorites
            ? "在记录右侧点击星标即可收藏。"
            : "成功完成的划词、词典和截图翻译会自动保存在这里。"
    }

    private func selectFirstVisibleEntryIfNeeded() {
        let visibleIDs = Set(store.entries.map(\.id))
        if let selectedID, visibleIDs.contains(selectedID) { return }
        selectedID = store.entries.first?.id
    }

    private func refreshQuery() {
        store.updateQuery(
            searchText: searchText,
            favoritesOnly: scope == .favorites
        )
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var transferAlertIsPresented: Binding<Bool> {
        Binding(
            get: { transferAlert != nil },
            set: { isPresented in
                if !isPresented {
                    transferAlert = nil
                }
            }
        )
    }

    private func exportEntries(favoritesOnly: Bool, format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.title = favoritesOnly ? "导出收藏记录" : "导出翻译历史"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let baseName = favoritesOnly ? "AutoTranslator-收藏" : "AutoTranslator-历史记录"
        panel.nameFieldStringValue =
            "\(baseName)-\(dateFormatter.string(from: Date())).\(format.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.exportEntries(favoritesOnly: favoritesOnly, format: format, to: url)
            transferAlert = HistoryTransferAlert(
                title: "导出完成",
                message: "已导出 \(count) 条\(favoritesOnly ? "收藏" : "历史")记录。"
            )
        } catch {
            transferAlert = HistoryTransferAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func importEntries() {
        let panel = NSOpenPanel()
        panel.title = "导入翻译历史"
        panel.message = "选择由 AutoTranslator 导出的 JSON 历史文件。"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try store.importEntries(from: url)
            transferAlert = HistoryTransferAlert(
                title: "导入完成",
                message: importSummary(for: result)
            )
        } catch {
            transferAlert = HistoryTransferAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func importSummary(for result: TranslationHistoryImportResult) -> String {
        let unchangedCount = result.acceptedCount - result.addedCount - result.updatedCount
        var fragments = ["已读取 \(result.acceptedCount) 条记录"]
        if result.addedCount > 0 {
            fragments.append("新增 \(result.addedCount) 条")
        }
        if result.updatedCount > 0 {
            fragments.append("合并更新 \(result.updatedCount) 条")
        }
        if unchangedCount > 0 {
            fragments.append("\(unchangedCount) 条无需变更")
        }
        return fragments.joined(separator: "；") + "。"
    }
}

private struct HistoryTransferAlert {
    let title: String
    let message: String
}

/// 导出选项弹窗：先选范围与格式（带用途说明），确认后再弹保存面板。
/// 取代原来藏在 `NSSavePanel` accessoryView 里的格式下拉框。
private struct HistoryExportSheet: View {
    let totalCount: Int
    let favoriteCount: Int
    let onConfirm: (_ favoritesOnly: Bool, _ format: HistoryExportFormat) -> Void
    let onCancel: () -> Void

    @State private var favoritesOnly = false
    @State private var format: HistoryExportFormat = .markdown

    private var exportCount: Int {
        favoritesOnly ? favoriteCount : totalCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.xl) {
            HStack(spacing: AppUI.Space.m) {
                SymbolBadge(
                    symbol: "square.and.arrow.up",
                    tint: AppUI.accent,
                    background: AppUI.activeToolbar,
                    size: 36
                )
                VStack(alignment: .leading, spacing: AppUI.Space.xxs) {
                    Text("导出记录")
                        .font(.system(size: AppUI.FontSize.title, weight: .bold, design: .serif))
                        .foregroundStyle(AppUI.textPrimary)
                    Text("选择导出范围与文件格式")
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: AppUI.Space.s) {
                sectionLabel("导出范围")
                HStack(spacing: AppUI.Space.m) {
                    ExportScopeCard(
                        title: "全部记录",
                        count: totalCount,
                        symbol: "clock.arrow.circlepath",
                        isSelected: !favoritesOnly
                    ) {
                        favoritesOnly = false
                    }
                    ExportScopeCard(
                        title: "仅收藏",
                        count: favoriteCount,
                        symbol: "star.fill",
                        isSelected: favoritesOnly
                    ) {
                        favoritesOnly = true
                    }
                    .disabled(favoriteCount == 0)
                    .opacity(favoriteCount == 0 ? 0.45 : 1)
                }
            }

            VStack(alignment: .leading, spacing: AppUI.Space.s) {
                sectionLabel("文件格式")
                VStack(spacing: AppUI.Space.s) {
                    ForEach(HistoryExportFormat.allCases) { candidate in
                        ExportFormatRow(
                            format: candidate,
                            isSelected: format == candidate
                        ) {
                            format = candidate
                        }
                    }
                }
            }

            HStack(spacing: AppUI.Space.m) {
                Text("将导出 \(exportCount) 条记录")
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
                Spacer(minLength: AppUI.Space.m)
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("导出…") {
                    onConfirm(favoritesOnly, format)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exportCount == 0)
            }
        }
        .padding(AppUI.Space.xxl)
        .frame(width: 460)
        .background(AppUI.panelBottom)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppUI.FontSize.mini, weight: .semibold))
            .foregroundStyle(AppUI.textMuted)
    }
}

private struct ExportScopeCard: View {
    let title: String
    let count: Int
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppUI.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: AppUI.FontSize.base, weight: .medium))
                    .foregroundStyle(isSelected ? AppUI.accent : AppUI.textMuted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: AppUI.Space.xxs) {
                    Text(title)
                        .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text("\(count) 条")
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppUI.Space.m)
            .padding(.vertical, AppUI.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(
                background: isSelected ? AppUI.activeToolbar : AppUI.surfaceSoft,
                radius: AppUI.controlRadius,
                border: isSelected ? AppUI.activeToolbarBorder : AppUI.buttonBorder
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ExportFormatRow: View {
    let format: HistoryExportFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppUI.Space.m) {
                SymbolBadge(
                    symbol: format.symbolName,
                    tint: isSelected ? AppUI.accent : AppUI.textSecondary,
                    background: isSelected ? AppUI.activeToolbar : AppUI.surfaceSoft,
                    size: 30
                )
                VStack(alignment: .leading, spacing: AppUI.Space.xxs) {
                    Text(format.title)
                        .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(format.caption)
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppUI.FontSize.section, weight: .medium))
                    .foregroundStyle(isSelected ? AppUI.accent : AppUI.textMuted)
            }
            .padding(.horizontal, AppUI.Space.m)
            .padding(.vertical, AppUI.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(
                background: isSelected ? AppUI.activeToolbar : AppUI.surfaceSoft,
                radius: AppUI.controlRadius,
                border: isSelected ? AppUI.activeToolbarBorder : AppUI.buttonBorder
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryEntryRow: View {
    let entry: TranslationHistoryEntry
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppUI.Space.m) {
            VStack(alignment: .leading, spacing: AppUI.Space.s) {
                Text(entry.sourceText)
                    .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineLimit(2)

                Text(entry.translatedText)
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
                    .lineLimit(2)

                HStack(spacing: AppUI.Space.s) {
                    Text(entry.kind.displayName)
                    Text("·")
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: AppUI.FontSize.micro, weight: .medium))
                .foregroundStyle(AppUI.textMuted)
            }

            Spacer(minLength: 0)

            Button(action: onToggleFavorite) {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(entry.isFavorite ? AppUI.amber : AppUI.textMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(entry.isFavorite ? "取消收藏" : "收藏")
        }
        .padding(.vertical, AppUI.Space.s)
        .contentShape(Rectangle())
    }
}

private struct HistoryEntryDetail: View {
    let entry: TranslationHistoryEntry
    let onToggleFavorite: () -> Void
    let onCopySource: () -> Void
    let onCopyTranslation: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Space.xl) {
                detailHeader
                textSection(
                    title: "原文",
                    symbol: "text.alignleft",
                    text: entry.sourceText,
                    copyAction: onCopySource
                )
                textSection(
                    title: entry.kind == .translation ? "译文" : "释义",
                    symbol: entry.kind == .translation ? "character.book.closed" : "book.closed",
                    text: entry.translatedText,
                    copyAction: onCopyTranslation
                )
            }
            .padding(AppUI.Space.xxl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppUI.panelBottom)
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: AppUI.Space.l) {
            VStack(alignment: .leading, spacing: AppUI.Space.s) {
                HStack(spacing: AppUI.Space.s) {
                    Chip(
                        text: entry.kind.displayName,
                        foreground: AppUI.accent,
                        background: AppUI.activeToolbar
                    )
                    Chip(text: entry.languageDescription)
                    Chip(text: entry.backendDescription)
                }

                Text(entry.createdAt.formatted(date: .long, time: .shortened))
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: onToggleFavorite) {
                Label(
                    entry.isFavorite ? "已收藏" : "收藏",
                    systemImage: entry.isFavorite ? "star.fill" : "star"
                )
            }
            .buttonStyle(.bordered)
            .tint(entry.isFavorite ? AppUI.amber : AppUI.textSecondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("删除这条记录")
        }
    }

    private func textSection(title: String,
                             symbol: String,
                             text: String,
                             copyAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Space.m) {
            HStack(spacing: AppUI.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: AppUI.FontSize.small, weight: .semibold))
                    .foregroundStyle(AppUI.accent)
                Text(title)
                    .font(.system(size: AppUI.FontSize.section, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)
                Spacer()
                Button(action: copyAction) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppUI.textSecondary)
            }

            Text(text)
                .font(.system(size: AppUI.FontSize.body))
                .foregroundStyle(AppUI.textPrimary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(AppUI.Space.xl)
        .appSurface(background: AppUI.surface, shadow: true)
    }
}
