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
    
    // Selection State
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isSelecting = false
    private var longPressGesture: UILongPressGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!
    
    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x:Int(-1), y:Int(-1))

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?
    
    // Prevent auto-scroll conflict during selection
    private var isManualScrolling = false

    private var isPickingFileForUpload = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        terminalController.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(nibName: nil, bundle: nil)
        terminalController.delegate = self
    }

    override func loadView() {
        super.loadView()

        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
        
        tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.separatorInset = .zero
        tableView.backgroundColor = .clear
        tableView.allowsSelection = false 
        tableView.delaysContentTouches = false
        
        textView = tableView

        textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
        textViewTapGestureRecognizer.delegate = self
        textViewTapGestureRecognizer.cancelsTouchesInView = false 
        textView.addGestureRecognizer(textViewTapGestureRecognizer)
        
        // --- Add Selection Gestures ---
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        textView.addGestureRecognizer(longPressGesture)
        
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        textView.addGestureRecognizer(panGesture)
        // -----------------------------

        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = textView
        keyInput.keyboardToolbarHeightChanged = { height in
            self.keyboardToolbarHeightChanged?(height)
        }
        keyInput.terminalInputDelegate = terminalController
        view.addSubview(keyInput)
        
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
        
        addKeyCommand(UIKeyCommand(title: .localize("COPY", comment: "Copy text"),
                                   image: UIImage(systemName: "doc.on.doc"),
                                   action: #selector(self.copy(_:)),
                                   input: "c",
                                   modifierFlags: .command))
        
        addKeyCommand(UIKeyCommand(title: .localize("PASTE", comment: "Paste text"),
                                   image: UIImage(systemName: "doc.on.clipboard"),
                                   action: #selector(self.paste(_:)),
                                   input: "v",
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
        
        if !hasStarted {
            do {
                try terminalController.startSubProcess()
                hasStarted = true
            } catch {
                failureError = error
                didReceiveError(error: error)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        keyInput.becomeFirstResponder()
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
    
    // MARK: - Focus Management
    
    override var canBecomeFirstResponder: Bool {
        return false 
    }
    
    // MARK: - Screen

    func updateScreenSize() {
        guard isViewLoaded, let _ = textView else { return }
        
        if isSplitViewResizing {
            return
        }

        var layoutSize = self.view.safeAreaLayoutGuide.layoutFrame.size
        layoutSize.width -= TerminalView.horizontalSpacing * 2
        layoutSize.height -= TerminalView.verticalSpacing * 2

        if layoutSize.width <= 1 || layoutSize.height <= 1 {
            return
        }
        
        let glyphSize = terminalController.fontMetrics.boundingBox
        if glyphSize.width <= 0.1 || glyphSize.height <= 0.1 {
            return
        }
        
        let cols = max(1, UInt16(layoutSize.width / glyphSize.width))
        let rows = max(1, UInt16(layoutSize.height / glyphSize.height.rounded(.up)))

        let newSize = ScreenSize(cols: cols, rows: rows, cellSize: glyphSize)
        
        if screenSize != newSize {
            screenSize = newSize
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        } else {
            self.scroll(animated: true)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
        clearSelection()
    }

    private func updateIsSplitViewResizing() {
        state.isSplitViewResizing = isSplitViewResizing
        if !isSplitViewResizing {
            updateScreenSize()
        }
    }

    private func updateShowsTitleView() {
        updateScreenSize()
    }

    // MARK: - Gestures & Selection
    
    private func locationToGrid(point: CGPoint) -> (col: Int, row: Int)? {
        guard isViewLoaded, tableView != nil else { return nil }
        guard let indexPath = tableView.indexPathForRow(at: point),
              let cell = tableView.cellForRow(at: indexPath) else { return nil }
        
        let charWidth = terminalController.fontMetrics.boundingBox.width
        if charWidth <= 0.1 { return nil }
        
        let localPoint = tableView.convert(point, to: cell.contentView)
        
        let col = Int(localPoint.x / charWidth)
        let row = indexPath.row
        
        let maxCol = Int(terminalController.screenSize?.cols ?? 80)
        let clampedCol = max(0, min(col, maxCol - 1))
        
        return (clampedCol, row)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard isViewLoaded else { return }
        
        switch gesture.state {
        case .began:
            let point = gesture.location(in: tableView)
            if let gridPos = locationToGrid(point: point) {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                isSelecting = true
                isManualScrolling = true
                
                // Select at least one character
                selectionStart = gridPos
                selectionEnd = gridPos
                
                tableView.reloadData()
                showMenuController(at: point)
            }
        default:
            break
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isViewLoaded else { return }
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .began, .changed:
            if isSelecting {
                if let gridPos = locationToGrid(point: point) {
                    selectionEnd = gridPos
                    tableView.reloadData()
                    UIMenuController.shared.hideMenu()
                }
            }
        case .ended:
            if isSelecting {
                isManualScrolling = false
                showMenuController(at: point)
            }
        default:
            break
        }
    }
    
    private func clearSelection() {
        guard isViewLoaded, tableView != nil else { return }
        selectionStart = nil
        selectionEnd = nil
        isSelecting = false
        isManualScrolling = false
        tableView.reloadData()
        UIMenuController.shared.hideMenu()
        
        if !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        }
    }
    
    private func showMenuController(at point: CGPoint) {
        if !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        }
        
        let menu = UIMenuController.shared
        let rect = CGRect(x: point.x, y: point.y - 20, width: 1, height: 1)
        
        if #available(iOS 13.0, *) {
            menu.showMenu(from: tableView, rect: rect)
        } else {
            menu.setTargetRect(rect, in: tableView)
            menu.setMenuVisible(true, animated: true)
        }
    }

    @objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            if isSelecting {
                clearSelection()
            } else {
                if !keyInput.isFirstResponder {
                    keyInput.becomeFirstResponder()
                }
            }
        }
    }
    
    // MARK: - Copy / Paste Logic
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return isSelecting && selectionStart != nil
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return false
    }
    
    override func copy(_ sender: Any?) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        
        let text = getSelectedText(start: start, end: end)
        UIPasteboard.general.string = text
    }
    
    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, let data = text.data(using: .utf8) {
            terminalController.write(data)
            clearSelection()
        }
    }
    
    private func getSelectedText(start: (col: Int, row: Int), end: (col: Int, row: Int)) -> String {
        let (minR, maxR, startCol, endCol) = normalizeSelection(start: start, end: end)
        
        var result = ""
        let safeMinRow = max(0, minR)
        let safeMaxRow = min(lines.count - 1, maxR)
        
        if safeMinRow > safeMaxRow { return "" }
        
        for rowIndex in safeMinRow...safeMaxRow {
            if let term = terminalController.terminal {
                // FIXED: Direct usage of rowIndex because 'lines' is already synced with absolute history
                // We do NOT add term.buffer.yDisp here because our lines array is already fully populated from 0.
                if let termLine = term.getLine(row: rowIndex) {
                     let str = termLine.translateToString()
                     let len = str.count
                     var s = 0
                     var e = len
                     
                     if rowIndex == safeMinRow {
                         s = min(len, startCol)
                     }
                     if rowIndex == safeMaxRow {
                         e = min(len, endCol + 1)
                     }
                     
                     if s < e {
                         let startIdx = str.index(str.startIndex, offsetBy: s)
                         let endIdx = str.index(str.startIndex, offsetBy: e)
                         result += str[startIdx..<endIdx]
                     }
                }
            }
            
            if rowIndex != safeMaxRow {
                result += "\n"
            }
        }
        return result
    }
    
    private func normalizeSelection(start: (col: Int, row: Int), end: (col: Int, row: Int)) -> (minRow: Int, maxRow: Int, startCol: Int, endCol: Int) {
        if start.row < end.row {
            return (start.row, end.row, start.col, end.col)
        } else if start.row > end.row {
            return (end.row, start.row, end.col, start.col)
        } else {
            return (start.row, start.row, min(start.col, end.col), max(start.col, end.col))
        }
    }


    // MARK: - Lifecycle

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
        guard isViewLoaded, tableView != nil else { return }
        state.fontMetrics = terminalController.fontMetrics
        state.colorMap = terminalController.colorMap
        tableView.reloadData()
    }
}

extension TerminalSessionViewController: TerminalControllerDelegate {

    func refresh(lines: inout [AnyView]) {
        guard isViewLoaded, tableView != nil else { return }
        state.lines = lines
        self.scroll()
    }
    
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        guard isViewLoaded, tableView != nil else { return }
        self.lines = lines
        self.cursor = cursor
        self.tableView.reloadData()
        self.scroll()
    }
    
    func scroll(animated: Bool = false) {
        guard isViewLoaded, tableView != nil else { return }
        if isSelecting || isManualScrolling { return }
        
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
        if gestureRecognizer == longPressGesture || gestureRecognizer == panGesture {
            return false
        }
        return gestureRecognizer == textViewTapGestureRecognizer
            && (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGesture && otherGestureRecognizer == tableView.panGestureRecognizer {
            return false
        }
        return false
    }
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard isPickingFileForUpload,
                    let url = urls.first else {
            return
        }
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

class SwiftUITableViewCell: UITableViewCell {
    private var hostingView: UIHostingView<AnyView>?
    private var selectionLayer: UIView!
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none
        
        selectionLayer = UIView()
        selectionLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
        selectionLayer.isHidden = true
        contentView.addSubview(selectionLayer)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder) 
    }
    
    func configure(with view: AnyView, selectionRange: Range<Int>?, charWidth: CGFloat) {
        if let existingHostingView = hostingView {
            existingHostingView.rootView = view
        } else {
            let newHostingView = UIHostingView(rootView: view)
            newHostingView.translatesAutoresizingMaskIntoConstraints = false
            newHostingView.backgroundColor = .clear
            contentView.addSubview(newHostingView)
            self.hostingView = newHostingView
            
            NSLayoutConstraint.activate([
                newHostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                newHostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                newHostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        
        if let range = selectionRange {
            let startX = CGFloat(range.lowerBound) * charWidth
            let width = CGFloat(range.count) * charWidth
            selectionLayer.frame = CGRect(x: startX, y: 0, width: width, height: contentView.bounds.height)
            selectionLayer.isHidden = false
            // FIXED: Bring selection layer to front so it overlays the text background
            contentView.bringSubviewToFront(selectionLayer)
        } else {
            selectionLayer.isHidden = true
        }
    }
}

extension TerminalSessionViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}

extension TerminalSessionViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.lines.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell") as? SwiftUITableViewCell ?? SwiftUITableViewCell(style: .default, reuseIdentifier: "Cell")
        
        if indexPath.row < self.lines.count {
            let line = self.lines[indexPath.row]
            let cursorX = (indexPath.row == cursor.y) ? cursor.x : -1
            
            let view = terminalController.stringSupplier.attributedString(line: line, cursorX: cursorX)
            
            var selectionRange: Range<Int>? = nil
            if let start = selectionStart, let end = selectionEnd {
                let (minR, maxR, startCol, endCol) = normalizeSelection(start: start, end: end)
                
                if indexPath.row >= minR && indexPath.row <= maxR {
                    let sCol = (indexPath.row == minR) ? startCol : 0
                    let eCol = (indexPath.row == maxR) ? endCol : Int.max
                    
                    let maxLineCols = Int(terminalController.screenSize?.cols ?? 80)
                    let actualEnd = min(eCol, maxLineCols)
                    
                    if sCol <= actualEnd {
                         selectionRange = sCol..<(actualEnd + 1)
                    }
                }
            }
            
            cell.configure(with: view, selectionRange: selectionRange, charWidth: terminalController.fontMetrics.boundingBox.width)
        }
        
        return cell
    }
    
}
