-- Раскладка окна образа: размер, вид, фон и места значков (как в Trunook).
--
--   osascript tools/dmg-window.applescript "MyPetBit 1.0.0"
--
-- Всё это хранится в .DS_Store тома, а пишет его только Finder. Поэтому tools/make-dmg.sh собирает образ
-- изменяемым, монтирует, обставляет здесь и лишь потом сжимает.
-- Значки не привязаны к рисунку фона: с полосой вкладок Finder сдвигает их вниз, поэтому под ними фон пуст.

on run argv
	set volumeName to item 1 of argv
	tell application "Finder"
		tell disk volumeName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set sidebar width of container window to 0
			-- Ширина ровно по фону (660), высота — по фону (540) с запасом на полосы вкладок и состояния.
			set the bounds of container window to {220, 120, 880, 660}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 96
			set text size of viewOptions to 12
			set background picture of viewOptions to file ".background:background.tiff"
			set position of item "MyPetBit.app" to {150, 340}
			set position of item "Applications" to {330, 340}
			set position of item "Install - Установка - 安装.txt" to {510, 340}
			-- Служебные папки видны при показе скрытых файлов — уводим их ниже окна.
			try
				set position of item ".background" to {80, 640}
			end try
			try
				set position of item ".fseventsd" to {240, 640}
			end try
			set statusbar visible of container window to false
			set toolbar visible of container window to false
			-- Finder сбрасывает .DS_Store не сразу: без паузы том отмонтируется раньше.
			update without registering applications
			delay 3
			close
		end tell
	end tell
end run
