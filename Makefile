# MyPetBit — сборка без Xcode (хватает Command Line Tools).
#   make install   собрать и поставить в /Applications
#   make run       то же и запустить
#   make test      тесты логики (swift-testing)
#   make cert      один раз: свой сертификат подписи, чтобы разрешения macOS не слетали после пересборки
#   make dmg       образ для релиза с контрольной суммой
SHELL   := /bin/bash
APP     := MyPetBit
DEST    ?= /Applications
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)

.PHONY: all bundle install run stop test cert dmg clean version

all: bundle

bundle:
	@tools/build-app.sh

stop:
	@pkill -x $(APP) 2>/dev/null || true

install: bundle stop
	@# Launch Services не успевает заметить подмену бандла, если открыть сразу после снятия прежнего.
	@sleep 1
	@rm -rf "$(DEST)/$(APP).app"
	@cp -R build/$(APP).app "$(DEST)/$(APP).app"
	@echo "Установлено: $(DEST)/$(APP).app"

run: install
	@open "$(DEST)/$(APP).app"

test:
	swift test

cert:
	@tools/make-cert.sh

dmg: bundle
	@tools/make-dmg.sh

version:
	@echo $(VERSION)

clean:
	@rm -rf .build build
