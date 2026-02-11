//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import SwiftUIX
import SwiftTerm
import NewTermCommon

// 自定义 Cell 用于绘制原生风格的蓝色选区背景
class TerminalSelectionCell: UITableViewCell {
    static let identifier = "TerminalSelectionCell"
    
    // 用于显示内容的 SwiftUI Hosting Controller
    private var hostingView: UIHostingView<AnyView>?
    // 用于显示选中高亮的蓝色视图
    private var selectionHighlightView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.tintColor.withAlphaComponent(0.3) // 原生蓝色半透明
        v.isHidden = true
        return v
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none // 禁用 TableView 自带的点击灰色效果
        
        // 添加高亮层 (在最底层)
        contentView.addSubview(selectionHighlightView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(view: AnyView, charWidth: CGFloat, lineHeight: CGFloat, selectionRange: Range<Int>?) {
        // 1. 配置 SwiftUI 内容
        if hostingView == nil {
            let hv = UIHostingView(rootView: view)
            hv.backgroundColor = .clear
            hv.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(hv)
            hostingView = hv
            
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hv.topAnchor.constraint(equalTo: contentView.topAnchor),
                hv.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        } else {
            hostingView?.rootView = view
        }
        
        // 确保高亮层在文字下方
        contentView.sendSubviewToBack(selectionHighlightView)
        
        // 2. 绘制选区 (Native Selection Look)
        if let range = selectionRange {
            selectionHighlightView.isHidden = false
            
            // 计算高亮区域的 Frame
            // x = 左边距 + (起始字符 * 字符宽度)
            let startX = TerminalView.horizontalSpacing + (CGFloat(range.lowerBound) * charWidth)
            let width = CGFloat(range.count) * charWidth
            
            // 稍微调整高度以填满行距，看起来更像原生文本选择
            selectionHighlightView.frame = CGRect(x: startX, y: 0, width: width, height: lineHeight)
        } else {
            selectionHighlightView.isHidden = true
        }
    }
}

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

    var keyboardToolbarHeightChanged: ((Double) -> Void)?
    var initialCommand: String?

    override var isSplitViewResizing: Bool {
        didSet { updateIsSplitViewResizing() }
    }
    override var showsTitleView: Bool {
        didSet { updateShowsTitleView() }
    }
    override var screenSize: ScreenSize? {
        get { terminalController.screenSize }
        set { terminalController.screenSize = newValue }
    }

    private var terminalController = TerminalController()
    private var keyInput = TerminalKeyInput(frame: .zero)
    private var textView: UIView!
    private var tableView: UITableView!
    private var textViewTapGestureRecognizer: UITapGestureRecognizer!
    
    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x: Int(-1), y: Int(-1))

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?
    
    private var isPickingFileForUpload = false

    // MARK: - Native Selection Properties (原生选择功能变量)
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isSelecting = false
    private var longPressGesture: UILongPressGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

        terminalController.delegate = self

        do {
            try terminalController.startSubProcess()
            hasStarted = true
        } catch {
            failureError = error
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        super.loadView()

        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

        // 修复：不要在这里调用 preferencesUpdated()，因为 tableView 还没初始化！
        
        tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.separatorInset = .zero
        tableView.backgroundColor = .clear
        tableView.allowsSelection = false // 禁用 TableView 自带的行选择
        
        // 注册自定义 Cell
        tableView.register(TerminalSelectionCell.self, forCellReuseIdentifier: TerminalSelectionCell.identifier)
        
        textView = tableView

        // 点击空白处取消选择 / 唤起键盘
        textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
        textViewTapGestureRecognizer.delegate = self
        textView.addGestureRecognizer(textViewTapGestureRecognizer)

        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = textView
        keyInput.keyboardToolbarHeightChanged = { height in
            self.keyboardToolbarHeightChanged?(height)
        }
        keyInput.terminalInputDelegate = terminalController
        view.addSubview(keyInput)
        
        // 修复：初始化完 tableView 后再调用更新，防止崩溃
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hudView = UIHostingView(rootView: AnyView(
            HUDView()
                .environmentObject(self.hudState)
        ))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        hudView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        view.addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])

        addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
                                   image: UIImage(systemName: "text.badge.xmark"),
                                   action: #selector(self.clearTerminal),
                                   input: "k",
                                   modifierFlags: .command))

        #if !targetEnvironment(macCatalyst)
        addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
                                   image: UIImage(systemName: "key.fill"),
                                   action: #selector(self.activatePasswordManager),
                                   input: "f",
                                   modifierFlags: [ .command ]))
        #endif

        if UIApplication.shared.supportsMultipleScenes {
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)

        // MARK: - Setup Selection Gestures (添加长按和拖拽手势)
        
        // 长按开始选择
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        tableView.addGestureRecognizer(longPressGesture)

        // 拖拽调整选区
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        tableView.addGestureRecognizer(panGesture)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !isSelecting {
            keyInput.becomeFirstResponder()
        }
        terminalController.terminalWillAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let error = failureError {
            didReceiveError(error: error)
        } else {
            if let initialCommand = initialCommand?.data(using: .utf8) {
                terminalController.write(initialCommand + EscapeSequences.return)
            }
        }
        initialCommand = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyInput.resignFirstResponder()
        terminalController.terminalWillDisappear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
    }

    // MARK: - Screen Update
    func updateScreenSize() {
        if isSplitViewResizing { return }

        var layoutSize = self.view.safeAreaLayoutGuide.layoutFrame.size
        layoutSize.width -= TerminalView.horizontalSpacing * 2
        layoutSize.height -= TerminalView.verticalSpacing * 2

        if layoutSize.width <= 0 || layoutSize.height <= 0 { return }
        
        let glyphSize = terminalController.fontMetrics.boundingBox
        if glyphSize.width == 0 || glyphSize.height == 0 { return }
        
        let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
                                 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
                                 cellSize: glyphSize)
        if screenSize != newSize {
            screenSize = newSize
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        } else {
            self.scroll(animated: true)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
    }

    private func updateIsSplitViewResizing() {
        state.isSplitViewResizing = isSplitViewResizing
        if !isSplitViewResizing { updateScreenSize() }
    }

    private func updateShowsTitleView() {
        updateScreenSize()
    }

    // MARK: - Native Selection Logic (核心选择逻辑)

    @objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            // 点击空白处：清除选区并弹出键盘
            if isSelecting {
                clearSelection()
            }
            if !keyInput.isFirstResponder {
                keyInput.becomeFirstResponder()
                delegate?.terminalDidBecomeActive(viewController: self)
            }
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .began:
            // 开始选择：计算手指下的坐标
            if let coord = getTerminalCoordinate(at: point) {
                isSelecting = true
                selectionStart = coord
                selectionEnd = coord
                
                // 震动反馈 (Taptic Engine)
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                // 隐藏键盘，显示菜单
                self.becomeFirstResponder()
                
                // 刷新界面显示高亮
                tableView.reloadData()
            }
        case .changed:
            // 长按移动时更新选区
            if let coord = getTerminalCoordinate(at: point) {
                // 修复编译错误：分别比较属性，避免可选元组比较错误
                if selectionEnd?.col != coord.col || selectionEnd?.row != coord.row {
                    selectionEnd = coord
                    tableView.reloadData()
                }
            }
        case .ended:
            showMenu(at: point)
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isSelecting else { return }
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .changed:
            // 拖拽时更新选区终点
            if let coord = getTerminalCoordinate(at: point) {
                // 自动滚动支持：如果拖到顶部或底部
                handleAutoScroll(at: point)
                
                // 修复编译错误：分别比较属性，避免可选元组比较错误
                if selectionEnd?.col != coord.col || selectionEnd?.row != coord.row {
                    selectionEnd = coord
                    tableView.reloadData() // 实时重绘高亮
                }
            }
        case .ended:
            showMenu(at: point)
        default:
            break
        }
    }

    // 将屏幕像素坐标转换为终端 (列, 行)
    private func getTerminalCoordinate(at point: CGPoint) -> (col: Int, row: Int)? {
        guard let indexPath = tableView.indexPathForRow(at: point) else { return nil }
        
        // 计算行内 X 坐标
        // 必须减去左侧间距
        let localX = point.x - TerminalView.horizontalSpacing
        let charWidth = terminalController.fontMetrics.boundingBox.width
        guard charWidth > 0 else { return nil }
        
        // 计算列号
        let col = Int(round(localX / charWidth))
        let maxCols = Int(screenSize?.cols ?? 80)
        
        // 限制在有效范围内
        let constrainedCol = max(0, min(col, maxCols))
        
        return (col: constrainedCol, row: indexPath.row)
    }
    
    // 简单的自动滚动逻辑
    private func handleAutoScroll(at point: CGPoint) {
        let topMargin: CGFloat = 40
        let bottomMargin: CGFloat = tableView.bounds.height - 40
        let contentOffset = tableView.contentOffset
        
        if point.y - contentOffset.y < topMargin {
            // 向上滚动
            tableView.setContentOffset(CGPoint(x: 0, y: max(0, contentOffset.y - 10)), animated: false)
        } else if point.y - contentOffset.y > bottomMargin {
            // 向下滚动
            tableView.setContentOffset(CGPoint(x: 0, y: min(tableView.contentSize.height, contentOffset.y + 10)), animated: false)
        }
    }

    private func clearSelection() {
        isSelecting = false
        selectionStart = nil
        selectionEnd = nil
        tableView.reloadData()
        UIMenuController.shared.hideMenu()
    }

    // 显示系统的复制菜单
    private func showMenu(at point: CGPoint) {
        self.becomeFirstResponder()
        
        // 计算菜单出现的位置（在选区末尾附近）
        var targetRect = CGRect(x: point.x, y: point.y, width: 2, height: 20)
        
        // 尝试定位到具体的字符位置
        if let end = selectionEnd {
             let indexPath = IndexPath(row: end.row, section: 0)
             let rowRect = tableView.rectForRow(at: indexPath)
             let charWidth = terminalController.fontMetrics.boundingBox.width
             let x = TerminalView.horizontalSpacing + CGFloat(end.col) * charWidth
             targetRect = CGRect(x: x, y: rowRect.origin.y, width: 2, height: rowRect.height)
        }

        let menu = UIMenuController.shared
        if #available(iOS 13.0, *) {
            menu.showMenu(from: tableView, rect: targetRect)
        } else {
            menu.setTargetRect(targetRect, in: tableView)
            menu.setMenuVisible(true, animated: true)
        }
    }

    // MARK: - Copy / Paste Actions (复制粘贴实现)

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            // 只有在选择了内容时才显示“复制”
            return isSelecting && selectionStart != nil
        }
        if action == #selector(paste(_:)) {
            // 剪贴板有内容时显示“粘贴”
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        
        // 1. 确定前后顺序
        let (p1, p2) = sortPositions(start, end)
        
        // 2. 构建字符串
        var resultText = ""
        
        // 遍历涉及的行
        for rowIndex in p1.row...p2.row {
            guard rowIndex >= 0 && rowIndex < lines.count else { continue }
            let line = lines[rowIndex]
            
            // 计算该行的截取范围
            let lineLength = line.count
            let startCol = (rowIndex == p1.row) ? p1.col : 0
            let endCol = (rowIndex == p2.row) ? p2.col : lineLength
            
            // 防止越界
            let safeStart = max(0, min(startCol, lineLength))
            let safeEnd = max(0, min(endCol, lineLength))
            
            if safeStart < safeEnd {
                // 提取该行文本
                var lineStr = ""
                for i in safeStart..<safeEnd {
                    // BufferLine 的具体 API 可能不同，这里假设可以用下标访问 CharData
                    // 如果 line[i] 返回的是 CharData，需要转换成 Character
                    let charData = line[i] 
                    let char = charData.getCharacter() 
                    // 忽略空字符
                    if char != Character(UnicodeScalar(0)) {
                        lineStr.append(char)
                    } else {
                        lineStr.append(" ") // 空白处补空格
                    }
                }
                resultText += lineStr
            }
            
            // 换行符（如果不是最后一行）
            if rowIndex != p2.row {
                resultText += "\n"
            }
        }
        
        // 3. 写入系统剪贴板
        UIPasteboard.general.string = resultText
        
        // 4. 完成后清除选区
        clearSelection()
        
        // 5. 恢复键盘输入
        keyInput.becomeFirstResponder()
    }

    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            // 转换为 UTF8 数组发送给终端后端
            terminalController.write(string.utf8Array)
        }
        clearSelection()
        keyInput.becomeFirstResponder()
    }

    // 辅助函数：确保坐标 p1 在 p2 之前
    private func sortPositions(_ p1: (col: Int, row: Int), _ p2: (col: Int, row: Int)) -> ((col: Int, row: Int), (col: Int, row: Int)) {
        if p1.row < p2.row { return (p1, p2) }
        if p1.row > p2.row { return (p2, p1) }
        return p1.col < p2.col ? (p1, p2) : (p2, p1)
    }

    // MARK: - Lifecycle Handlers
    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        if notification.object as? UIWindowScene == view.window?.windowScene {
            terminalController.windowDidEnterBackground()
        }
    }

    @objc private func sceneWillEnterForeground(_ notification: Notification) {
        if notification.object as? UIWindowScene == view.window?.windowScene {
            terminalController.windowWillEnterForeground()
        }
    }

    @objc private func preferencesUpdated() {
        state.fontMetrics = terminalController.fontMetrics
        state.colorMap = terminalController.colorMap
        // 修复：确保 tableView 存在再刷新，虽然我们在 loadView 调整了顺序，但这是为了保险
        tableView?.reloadData()
    }
}

// MARK: - TerminalControllerDelegate
extension TerminalSessionViewController: TerminalControllerDelegate {

    func refresh(lines: inout [AnyView]) {
        state.lines = lines
        self.scroll()
    }
    
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        self.lines = lines
        self.cursor = cursor
        // 刷新列表以显示最新内容
        // 注意：在大数据量下 reloadData 可能有性能影响，但在终端场景通常是可以接受的
        self.tableView.reloadData()
        self.scroll()
    }
    
    func scroll(animated: Bool = false) {
        // 如果用户正在选择文本，不要自动滚动干扰
        guard !isSelecting else { return }
        
        state.scroll += 1
        
        let lastRow = self.tableView.numberOfRows(inSection: 0) - 1
        if lastRow >= 0 {
            let indexPath = IndexPath(row: lastRow, section: 0)
            self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
        }
    }

    func activateBell() {
        if Preferences.shared.bellHUD {
            hudState.isVisible = true
        }
        HapticController.playBell()
    }

    func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
        let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
        delegate?.terminal(viewController: self,
                           titleDidChange: newTitle,
                           isDirty: isDirty,
                           hasBell: hasBell)
    }

    func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
        #if targetEnvironment(macCatalyst)
        if let windowScene = view.window?.windowScene {
            windowScene.titlebar?.representedURL = url
        }
        #endif
    }

    func saveFile(url: URL) {
        let viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        viewController.delegate = self
        present(viewController, animated: true, completion: nil)
    }

    func fileUploadRequested() {
        isPickingFileForUpload = true
        let viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
        viewController.delegate = self
        present(viewController, animated: true, completion: nil)
    }

    @objc func activatePasswordManager() {
        keyInput.activatePasswordManager()
    }

    @objc func close() {
        if let splitViewController = parent as? TerminalSplitViewController {
            splitViewController.remove(viewController: self)
        }
    }

    func didReceiveError(error: Error) {
        if !hasAppeared {
            failureError = error
            return
        }
        failureError = nil
        let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
                                                message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
                                                preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
        present(alertController, animated: true, completion: nil)
    }
}

extension TerminalSessionViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == textViewTapGestureRecognizer {
            return (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
        }
        // 如果是拖拽手势，在选择模式下接管控制
        if gestureRecognizer == panGesture {
            return isSelecting
        }
        return false
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGesture {
            return isSelecting
        }
        return true
    }
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard isPickingFileForUpload, let url = urls.first else { return }
        terminalController.uploadFile(url: url)
        isPickingFileForUpload = false
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if isPickingFileForUpload {
            isPickingFileForUpload = false
            terminalController.cancelUploadRequest()
        } else {
            terminalController.deleteDownloadCache()
        }
    }
}

// MARK: - Table View Data Source (渲染逻辑)
extension TerminalSessionViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.lines.count
    }
    
    // 渲染每一行
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 使用我们自定义的 TerminalSelectionCell
        guard let cell = tableView.dequeueReusableCell(withIdentifier: TerminalSelectionCell.identifier, for: indexPath) as? TerminalSelectionCell else {
            return UITableViewCell()
        }
        
        let line = self.lines[indexPath.row]
        let view = terminalController.stringSupplier.attributedString(line: line, cursorX: indexPath.row == cursor.y ? cursor.x : -1)
        
        // 计算当前行在选中区域内的范围
        var rangeInLine: Range<Int>? = nil
        
        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let (p1, p2) = sortPositions(start, end)
            
            // 如果当前行在选区范围内
            if indexPath.row >= p1.row && indexPath.row <= p2.row {
                let sCol = (indexPath.row == p1.row) ? p1.col : 0
                // 如果是最后一行，终点是 p2.col；否则是整行长度 (给一个足够大的数即可，因为是视觉效果)
                let eCol = (indexPath.row == p2.row) ? p2.col : 1000 
                
                if sCol < eCol {
                    rangeInLine = sCol..<eCol
                }
            }
        }
        
        // 配置 Cell
        let metrics = terminalController.fontMetrics.boundingBox
        cell.configure(view: view, charWidth: metrics.width, lineHeight: metrics.height, selectionRange: rangeInLine)
        
        return cell
    }
    
    // 禁用默认的选中高亮
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}
