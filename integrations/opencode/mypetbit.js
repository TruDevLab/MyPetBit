// Бит (MyPetBit): пока OpenCode отвечает — Бит «работает»; ответил или просит разрешение — облачко и значок.
// Передаёт события запущенному Биту командой MyPetBit --agent-hook opencode (JSON — на stdin).
// Бит не запущен или бинарника нет — молча ничего не делает.
import { spawn } from "node:child_process"

const BIT = "/Applications/MyPetBit.app/Contents/MacOS/MyPetBit"

function tell(payload) {
  try {
    const child = spawn(BIT, ["--agent-hook", "opencode"], { stdio: ["pipe", "ignore", "ignore"], detached: true })
    child.on("error", () => {})
    child.stdin.on("error", () => {})
    child.stdin.end(JSON.stringify(payload))
    child.unref()
  } catch {}
}

export const MyPetBit = async ({ client, directory }) => {
  const busy = new Set()
  const info = new Map()  // сессия → { title, child }: подзадачи (дочерние сессии) не объявляем

  async function session(id) {
    if (info.has(id)) return info.get(id)
    let value = { title: undefined, child: false }
    try {
      const res = await client.session.get({ path: { id } })
      value = { title: res?.data?.title, child: Boolean(res?.data?.parentID) }
    } catch {}
    info.set(id, value)
    return value
  }

  return {
    event: async ({ event }) => {
      const props = event.properties ?? {}
      const id = props.sessionID
      if (!id) return
      if (event.type === "session.status" && props.status?.type === "busy") {
        if (busy.has(id) || (await session(id)).child) return
        busy.add(id)
        tell({ hook_event_name: "UserPromptSubmit", session_id: id, cwd: directory })
      } else if (event.type === "session.idle" || (event.type === "session.status" && props.status?.type === "idle")) {
        if (!busy.delete(id)) return
        info.delete(id)  // заголовок мог появиться за время ответа
        const s = await session(id)
        tell({ hook_event_name: "Stop", session_id: id, cwd: directory, session_title: s.title })
      } else if (event.type === "permission.asked" || event.type === "permission.updated") {
        if ((await session(id)).child) return
        tell({ hook_event_name: "Notification", message: "permission", session_id: id, cwd: directory })
      }
    },
  }
}
