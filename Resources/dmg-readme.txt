MyPetBit — установка / Installation / 安装
=========================================

РУССКИЙ
-------
1. Перетащите MyPetBit в папку «Программы».
2. Откройте Терминал и выполните:
     sudo xattr -r -c /Applications/MyPetBit.app
   Терминал спросит пароль учётной записи — при вводе он не отображается, это нормально.
3. Запустите MyPetBit. Бит появится в правом нижнем углу, значок — в строке меню (в Dock значка нет).

Зачем второй шаг: macOS не открывает скачанные приложения, подписанные не сертификатом разработчика Apple.
MyPetBit подписан самодельным сертификатом. Команда снимает служебные пометки (включая карантин) только
с этого приложения и не отключает защиту системы. Проверить подпись:
     codesign --verify --deep --strict /Applications/MyPetBit.app
Надёжнее всего собрать из исходников: make install (см. README).


ENGLISH
-------
1. Drag MyPetBit to the Applications folder.
2. Open Terminal and run:
     sudo xattr -r -c /Applications/MyPetBit.app
   Terminal asks for your account password — it is not shown while you type, that is normal.
3. Launch MyPetBit. Bit appears in the bottom-right corner, its icon in the menu bar (no Dock icon).

Why step 2: macOS refuses to open downloaded apps that are not signed with an Apple Developer certificate.
MyPetBit is signed with a self-made certificate. The command removes extended attributes (including quarantine)
from this one app only and does not turn off system protection. To check the signature:
     codesign --verify --deep --strict /Applications/MyPetBit.app
The most reliable way is to build from source: make install (see README).


简体中文
--------
1. 把 MyPetBit 拖到“应用程序”文件夹。
2. 打开“终端”，执行：
     sudo xattr -r -c /Applications/MyPetBit.app
   终端会要求输入账户密码——输入时不显示，这是正常的。
3. 启动 MyPetBit。Bit 会出现在屏幕右下角，图标在菜单栏中（没有 Dock 图标）。

为什么需要第 2 步：macOS 不会打开未用 Apple 开发者证书签名的下载应用。MyPetBit 使用自制证书签名。
该命令只移除这个应用的扩展属性（包括隔离属性），不会关闭系统保护。检查签名：
     codesign --verify --deep --strict /Applications/MyPetBit.app
最可靠的方式是从源码构建：make install（见 README）。
