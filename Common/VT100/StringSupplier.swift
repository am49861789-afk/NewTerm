//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

fileprivate extension View {
	static func + (lhs: Self, rhs: some View) -> AnyView {
		AnyView(ViewBuilder.buildBlock(lhs, AnyView(rhs)))
	}
}

open class StringSupplier {

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

    public func attributedString(forScrollInvariantRow row: Int) -> AnyView {
        guard let terminal = terminal else {
            fatalError()
        }
        
        //		guard let line = terminal.getScrollInvariantLine(row: row) else {
        //			return AnyView(EmptyView())
        //		}
        let line = terminal.buffer.lines[row]
        //        NSLog("NewTermLog: line[\(row)]=\(line)")
        
        let cursorPosition = terminal.getCursorLocation()
        let scrollbackRows = terminal.getTopVisibleRow()

        return attributedString(line: line, cursorX: row - scrollbackRows == cursorPosition.y ? cursorPosition.x : -1)
    }
    
    public func attributedString(line: BufferLine, cursorX: Int) -> AnyView {
		var lastAttribute = Attribute.empty
		var views = [AnyView]()
		var buffer = ""
        for j in 0..<line.count {
			let data = line[j]
			let isCursor = cursorVisible && j == cursorX

			if isCursor || lastAttribute != data.attribute {
				// Finish up the last run by appending it to the attributed string, then reset for the
				// next run.
				views.append(text(buffer, attribute: lastAttribute))
				lastAttribute = data.attribute
				buffer.removeAll()
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)

			if isCursor {
				// We may need to insert a space for the cursor to show up.
				if buffer.isEmpty {
					buffer.append(" ")
				}

				views.append(text(buffer, attribute: lastAttribute, isCursor: true))
				buffer.removeAll()
			}
		}

		// Append the final run
		views.append(text(buffer, attribute: lastAttribute))

		return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		}
//        .frame(maxWidth: .infinity, alignment: .leading)
        )
	}

	private func text(_ run: String, attribute: Attribute, isCursor: Bool = false) -> AnyView {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		let width = CGFloat(run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) })) * (fontMetrics?.width ?? 0)

		return AnyView(
			Text(run)
				// Text attributes
				.foregroundColor(Color(foreground ?? .white))
				.font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
				.underline(attribute.style.contains(.underline))
				.strikethrough(attribute.style.contains(.crossedOut))
				.tracking(0)
				// View attributes
				.allowsTightening(false)
				.lineLimit(1)
				.background(Color(background ?? .black))
				.frame(width: width)
				.fixedSize(horizontal: false, vertical: true)
		)
	}

	// 👇 新增方法：用于为全局 UITextView 生成原生的 NSAttributedString
	public func buildNSAttributedString(line: BufferLine, cursorX: Int) -> NSAttributedString {
		let result = NSMutableAttributedString()
		
		var lastAttribute = Attribute.empty
		var buffer = ""
		
		// 内部闭包：处理当前的文本切片，并附加上颜色和字体属性
		let appendBufferToResult = { (isCursor: Bool) in
			guard !buffer.isEmpty || isCursor else { return }
			
			var fgColor = lastAttribute.fg
			var bgColor = lastAttribute.bg

			// 1. 处理反转色
			if lastAttribute.style.contains(.inverse) {
				swap(&bgColor, &fgColor)
				if fgColor == .defaultColor { fgColor = .defaultInvertedColor }
				if bgColor == .defaultColor { bgColor = .defaultInvertedColor }
			}

			// 2. 映射前景色和背景色 (返回 UIColor 对象)
			let foreground = self.colorMap?.color(
				for: fgColor,
				isForeground: true,
				isBold: lastAttribute.style.contains(.bold),
				isCursor: isCursor
			) ?? UIColor.white

			let background = self.colorMap?.color(
				for: bgColor,
				isForeground: false,
				isCursor: isCursor
			) ?? UIColor.black

			// 3. 映射字体
			let font: UIFont
			if lastAttribute.style.contains(.bold) || lastAttribute.style.contains(.blink) {
				font = lastAttribute.style.contains(.italic)
					? (self.fontMetrics?.boldItalicFont ?? .boldSystemFont(ofSize: 12))
					: (self.fontMetrics?.boldFont ?? .boldSystemFont(ofSize: 12))
			} else if lastAttribute.style.contains(.dim) {
				font = lastAttribute.style.contains(.italic)
					? (self.fontMetrics?.lightItalicFont ?? .systemFont(ofSize: 12))
					: (self.fontMetrics?.lightFont ?? .systemFont(ofSize: 12))
			} else {
				font = lastAttribute.style.contains(.italic)
					? (self.fontMetrics?.italicFont ?? .italicSystemFont(ofSize: 12))
					: (self.fontMetrics?.regularFont ?? .systemFont(ofSize: 12))
			}

            // 👇 新增：创建一个严格的终端段落样式，禁止 UITextView 自作聪明地按单词换行
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping // 终端已经计算好换行了，直接裁剪多余像素，绝不二次换行

			// 4. 打包原生属性字典
			var attributes: [NSAttributedString.Key: Any] = [
				.font: font,
				.foregroundColor: foreground,
				.backgroundColor: background,
                .paragraphStyle: paragraphStyle // 👈 将段落样式加进字典里
			]

			// 5. 下划线与删除线
			if lastAttribute.style.contains(.underline) {
				attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
			}
			if lastAttribute.style.contains(.crossedOut) {
				attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
			}

			// 如果是光标位置且为空，补充一个空格防止光标不可见
			let textToAppend = (isCursor && buffer.isEmpty) ? " " : buffer
			
			result.append(NSAttributedString(string: textToAppend, attributes: attributes))
		}

		// 遍历该行终端字符，寻找颜色/样式的断点
		for j in 0..<line.count {
			let data = line[j]
			let isCursor = cursorVisible && j == cursorX

			// 遇到属性变化，或者遇到了光标，先结算之前的字符串
			if isCursor || lastAttribute != data.attribute {
				appendBufferToResult(false)
				lastAttribute = data.attribute
				buffer.removeAll()
			}

			let character = data.getCharacter()
			// 终端中的 Null 字符替换为空格
			buffer.append(character == "\0" ? " " : String(character))

			// 单独结算光标
			if isCursor {
				appendBufferToResult(true)
				buffer.removeAll()
			}
		}

		// 遍历结束后，追加最后遗留的一段字符
		appendBufferToResult(false)

		return result
	}
}
