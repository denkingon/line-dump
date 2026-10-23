-- 使い方: osascript ocr.applescript <画像パス>
-- 出力: 「文字列<TAB>中心x<TAB>中心y<TAB>幅<TAB>高さ」（画像px・左上原点）を1行ずつ
--
-- macOS 標準の Vision OCR を AppleScriptObjC から呼ぶ（追加インストール不要）。
-- line_export.lua が画面を撮るたびにこれで文字と位置を読み、押す場所を決める。
-- 2026-10-20 に実機で動作確認済み（設計書 LINE_v4_design.md のまま）。
-- 罠: AppleScript では変数名 handler が予約語で使えないので vh にしている。
use framework "Foundation"
use framework "Vision"
use framework "AppKit"
use scripting additions
on run argv
	set p to item 1 of argv
	set rep to current application's NSImageRep's imageRepWithContentsOfFile:p
	set W to (rep's pixelsWide()) as real
	set H to (rep's pixelsHigh()) as real
	set vh to current application's VNImageRequestHandler's alloc()'s initWithURL:(current application's NSURL's fileURLWithPath:p) options:(current application's NSDictionary's dictionary())
	set req to current application's VNRecognizeTextRequest's alloc()'s init()
	req's setRecognitionLevel:0
	req's setRecognitionLanguages:{"ja-JP", "en-US"}
	req's setUsesLanguageCorrection:false
	vh's performRequests:{req} |error|:(missing value)
	set out to {}
	repeat with o in (req's results() as list)
		set s to ((o's topCandidates:1)'s firstObject()'s |string|()) as text
		set bb to o's boundingBox()
		try
			set ox to item 1 of item 1 of bb
			set oy to item 2 of item 1 of bb
			set bw to item 1 of item 2 of bb
			set bh to item 2 of item 2 of bb
		on error
			set ox to x of origin of bb
			set oy to y of origin of bb
			set bw to width of |size| of bb
			set bh to height of |size| of bb
		end try
		set end of out to s & tab & (round ((ox + bw / 2) * W)) & tab & (round ((1 - (oy + bh / 2)) * H)) & tab & (round (bw * W)) & tab & (round (bh * H))
	end repeat
	set AppleScript's text item delimiters to linefeed
	return out as text
end run
