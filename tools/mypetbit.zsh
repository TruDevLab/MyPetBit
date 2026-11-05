# Хук zsh для Бита (MyPetBit): о долгой команде он узнаёт сразу и с кодом выхода — «Команда упала» с грустным Битом.
# Без хука Бит тоже замечает долгие команды (по процессам), но не знает, чем они кончились.
# Подключение — строка в ~/.zshrc (путь — где лежит этот файл):
#   source "/путь/к/MyPetBit/tools/mypetbit.zsh"
# Короче 10 секунд Бита не зовём; порог он применяет сам (меню «Сообщать о командах»).

zmodload zsh/datetime 2>/dev/null || return 0

# Путь к себе — из $0 (при source это файл); через %x кириллица в пути портится без UTF-8 в окружении.
typeset -g _mypetbit_self=${0:A}
[[ $_mypetbit_self == *mypetbit.zsh ]] || _mypetbit_self=${${(%):-%x}:A}
# Хук внутри приложения (подключён из настроек Бита) — зовём этого Бита; иначе — Бита в «Программах»,
# иначе — сборку рядом с этим файлом (хук из исходников).
typeset -g _mypetbit_bin=""
[[ $_mypetbit_self == */Contents/Resources/mypetbit.zsh ]] && _mypetbit_bin="${_mypetbit_self:h:h}/MacOS/MyPetBit"
[[ -x $_mypetbit_bin ]] || _mypetbit_bin="/Applications/MyPetBit.app/Contents/MacOS/MyPetBit"
[[ -x $_mypetbit_bin ]] || _mypetbit_bin="${_mypetbit_self:h:h}/build/MyPetBit.app/Contents/MacOS/MyPetBit"
typeset -g _mypetbit_start=""
typeset -g _mypetbit_command=""

_mypetbit_preexec() {
    _mypetbit_start=$EPOCHREALTIME
    _mypetbit_command=$1
}

_mypetbit_precmd() {
    local status_code=$?
    [[ -n $_mypetbit_start ]] || return $status_code
    local seconds=$(( EPOCHREALTIME - _mypetbit_start ))
    _mypetbit_start=""
    if (( seconds >= 10 )) && [[ -x $_mypetbit_bin ]]; then
        "$_mypetbit_bin" --command-done --status $status_code --seconds ${seconds%.*} \
            --tty "$TTY" --shell $$ --command "$_mypetbit_command" &>/dev/null &!
    fi
    return $status_code
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _mypetbit_preexec
# Первым в списке: код выхода нужно взять раньше, чем его сменят другие хуки (темы приглашения и т. п.).
precmd_functions=(_mypetbit_precmd ${precmd_functions:#_mypetbit_precmd})
