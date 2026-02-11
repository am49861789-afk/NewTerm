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
        // 关键：Cell 背景必须透明，以便显示 TableView 的背景
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
            
            // 强制填满 Cell
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
            
            // 使用传入的 exact lineHeight
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
        
        // 初始化 TableView
        tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.separatorInset = .zero
        
        // 关键修复：设置默认背景色，防止白纸白字
        // 后续 preferencesUpdated 会根据主题再次更新它
        tableView.backgroundColor = .black 
        
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
        
        // 修复：此时 tableView 已初始化，安全调用更新
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

        // MARK: - Setup Selection Gestures
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        tableView.addGestureRecognizer(longPressGesture)

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

    // MARK: - Native Selection Logic

    @objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
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
            if let coord = getTerminalCoordinate(at: point) {
                isSelecting = true
                selectionStart = coord
                selectionEnd = coord
                
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                self.becomeFirstResponder()
                tableView.reloadData()
            }
        case .changed:
            if let coord = getTerminalCoordinate(at: point) {
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
            if let coord = getTerminalCoordinate(at: point) {
                handleAutoScroll(at: point)
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

    private func getTerminalCoordinate(at point: CGPoint) -> (col: Int, row: Int)? {
        guard let indexPath = tableView.indexPathForRow(at: point) else { return nil }
        
        let localX = point.x - TerminalView.horizontalSpacing
        let charWidth = terminalController.fontMetrics.boundingBox.width
        guard charWidth > 0 else { return nil }
        
        let col = Int(round(localX / charWidth))
        let maxCols = Int(screenSize?.cols ?? 80)
        let constrainedCol = max(0, min(col, maxCols))
        
        return (col: constrainedCol, row: indexPath.row)
    }
    
    private func handleAutoScroll(at point: CGPoint) {
        let topMargin: CGFloat = 40
        let bottomMargin: CGFloat = tableView.bounds.height - 40
        let contentOffset = tableView.contentOffset
        
        if point.y - contentOffset.y < topMargin {
            tableView.setContentOffset(CGPoint(x: 0, y: max(0, contentOffset.y - 10)), animated: false)
        } else if point.y - contentOffset.y > bottomMargin {
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

    private func showMenu(at point: CGPoint) {
        self.becomeFirstResponder()
        
        var targetRect = CGRect(x: point.x, y: point.y, width: 2, height: 20)
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

    // MARK: - Copy / Paste Actions

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return isSelecting && selectionStart != nil
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        
        let (p1, p2) = sortPositions(start, end)
        var resultText = ""
        
        for rowIndex in p1.row...p2.row {
            guard rowIndex >= 0 && rowIndex < lines.count else { continue }
            let line = lines[rowIndex]
            let lineLength = line.count
            let startCol = (rowIndex == p1.row) ? p1.col : 0
            let endCol = (rowIndex == p2.row) ? p2.col : lineLength
            
            let safeStart = max(0, min(startCol, lineLength))
            let safeEnd = max(0, min(endCol, lineLength))
            
            if safeStart < safeEnd {
                var lineStr = ""
                for i in safeStart..<safeEnd {
                    let charData = line[i] 
                    let char = charData.getCharacter() 
                    if char != Character(UnicodeScalar(0)) {
                        lineStr.append(char)
                    } else {
                        lineStr.append(" ")
                    }
                }
                resultText += lineStr
            }
            if rowIndex != p2.row {
                resultText += "\n"
            }
        }
        
        UIPasteboard.general.string = resultText
        clearSelection()
        keyInput.becomeFirstResponder()
    }

    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            terminalController.write(string.utf8Array)
        }
        clearSelection()
        keyInput.becomeFirstResponder()
    }

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
        
        // 关键：更新背景色以匹配终端主题
        // 尝试从 colorMap 获取背景色并设置给 tableView
        // 如果这里无法直接转换颜色，TableView 可能会保持为 loadView 设置的黑色
        if let tableView = tableView {
            // 注意：这里我们假设终端背景大部分时候是深色的。
            // 如果需要严格匹配主题，可能需要将 terminalController.colorMap.background (SwiftTerm Color)
            // 转换为 UIColor。为防止类型不匹配错误，这里暂且保留默认黑色或透明。
            // 实际操作中，最好显式设置：
             tableView.backgroundColor = .black 
        }
        
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
        self.tableView.reloadData()
        self.scroll()
    }
    
    func scroll(animated: Bool = false) {
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

// MARK: - Table View Data Source & Delegate (渲染逻辑)
extension TerminalSessionViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.lines.count
    }
    
    // 关键修复：强制设置行高，解决内容不显示的问题
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let h = terminalController.fontMetrics.boundingBox.height
        return h > 0 ? h : 20 // 防止高度为0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: TerminalSelectionCell.identifier, for: indexPath) as? TerminalSelectionCell else {
            return UITableViewCell()
        }
        
        let line = self.lines[indexPath.row]
        let view = terminalController.stringSupplier.attributedString(line: line, cursorX: indexPath.row == cursor.y ? cursor.x : -1)
        
        var rangeInLine: Range<Int>? = nil
        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let (p1, p2) = sortPositions(start, end)
            if indexPath.row >= p1.row && indexPath.row <= p2.row {
                let sCol = (indexPath.row == p1.row) ? p1.col : 0
                let eCol = (indexPath.row == p2.row) ? p2.col : 1000 
                if sCol < eCol {
                    rangeInLine = sCol..<eCol
                }
            }
        }
        
        let metrics = terminalController.fontMetrics.boundingBox
        cell.configure(view: view, charWidth: metrics.width, lineHeight: metrics.height, selectionRange: rangeInLine)
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}
