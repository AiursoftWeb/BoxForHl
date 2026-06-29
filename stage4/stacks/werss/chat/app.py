import os, re, json, time, secrets, logging
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse, RedirectResponse
import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("chat")
app = FastAPI()

WERSS_BASE = os.environ.get("WERSS_BASE", "http://werss_server:8001")
DEEPSEEK_URL = "https://api.deepseek.com/v1/chat/completions"
COOKIE = "werss_chat_sid"

# Login reuses the werss account: the user signs in with their werss credentials,
# we validate against werss's own login API and keep their JWT in a server-side
# session. That same JWT is then used to fetch articles — no static password here.
# Single-user tool, so an in-memory session store is fine (re-login after restart).
SESSIONS = {}  # sid -> {"token": jwt, "expires": epoch}


def _session(request: Request):
    sid = request.cookies.get(COOKIE)
    s = SESSIONS.get(sid) if sid else None
    if s and s["expires"] > time.time():
        return sid, s
    if sid in SESSIONS:
        SESSIONS.pop(sid, None)
    return None, None


def _list(payload):
    """Unwrap the werss `{code, message, data: {list: [...]}}` envelope."""
    if isinstance(payload, dict):
        data = payload.get("data", payload)
        if isinstance(data, dict):
            return data.get("list", [])
        if isinstance(data, list):
            return data
    if isinstance(payload, list):
        return payload
    return []


def _strip_html(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s or "")).strip()


LOGIN_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WeRSS Chat 登录</title>
<style>
:root{--bg:#0f0f0f;--surface:#1a1a1a;--border:#2a2a2a;--text:#e0e0e0;--muted:#888;--accent:#4ade80}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);height:100vh;display:flex;align-items:center;justify-content:center}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:32px;width:320px;display:flex;flex-direction:column;gap:14px}
.card h1{font-size:18px;text-align:center}
.card .sub{font-size:12px;color:var(--muted);text-align:center;margin-top:-6px}
.card input{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;color:var(--text);font-size:14px;outline:none}
.card input:focus{border-color:var(--accent)}
.card button{background:var(--accent);color:#000;border:none;border-radius:8px;padding:10px;font-size:14px;font-weight:600;cursor:pointer}
.card button:disabled{opacity:.5}
#err{color:#fca5a5;font-size:12px;text-align:center;min-height:14px}
</style></head><body>
<form class="card" onsubmit="return doLogin(event)">
  <h1>&#x1F4E1; WeRSS Chat</h1>
  <div class="sub">使用你的 WeRSS 账号登录</div>
  <input id="u" placeholder="用户名" autocomplete="username" autofocus>
  <input id="p" type="password" placeholder="密码" autocomplete="current-password">
  <button id="b" type="submit">登录</button>
  <div id="err"></div>
</form>
<script>
async function doLogin(e){
  e.preventDefault();
  const b=document.getElementById('b'),err=document.getElementById('err');
  b.disabled=true;err.textContent='';
  const body=new URLSearchParams({username:u.value.trim(),password:p.value});
  try{
    const r=await fetch('/chat/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body});
    if(r.ok){location.href='/chat';}
    else{const t=await r.json().catch(()=>({detail:'登录失败'}));err.textContent=t.detail||'用户名或密码错误';b.disabled=false;}
  }catch(ex){err.textContent='连接失败: '+ex.message;b.disabled=false;}
  return false;
}
</script></body></html>"""


CHAT_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WeRSS Chat</title>
<style>
:root{--bg:#0f0f0f;--surface:#1a1a1a;--border:#2a2a2a;--text:#e0e0e0;--muted:#888;--accent:#4ade80;--accent-hover:#22c55e}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'SF Pro Display','Segoe UI',sans-serif;background:var(--bg);color:var(--text);height:100vh;display:flex;flex-direction:column}
header{background:var(--surface);border-bottom:1px solid var(--border);padding:12px 20px;display:flex;align-items:center;gap:12px}
header h1{font-size:16px;font-weight:600}
#status{font-size:12px;color:var(--muted);margin-left:auto}
#logout{font-size:12px;color:var(--muted);cursor:pointer;border:1px solid var(--border);border-radius:6px;padding:4px 10px;background:var(--bg)}
main{flex:1;overflow-y:auto;padding:20px;display:flex;flex-direction:column;gap:16px}
.msg{padding:12px 16px;border-radius:12px;max-width:85%;line-height:1.6;font-size:14px;white-space:pre-wrap;word-break:break-word}
.msg.user{align-self:flex-end;background:var(--accent);color:#000}
.msg.assistant{align-self:flex-start;background:var(--surface);border:1px solid var(--border)}
.msg.error{align-self:flex-start;background:#3b1111;border:1px solid #f87171;color:#fca5a5}
.msg .meta{font-size:11px;color:var(--muted);margin-bottom:4px}
.msg.user .meta{color:rgba(0,0,0,.5)}
footer{background:var(--surface);border-top:1px solid var(--border);padding:12px 20px;display:flex;gap:8px}
footer input{flex:1;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 14px;color:var(--text);font-size:14px;outline:none}
footer input:focus{border-color:var(--accent)}
footer button{background:var(--accent);color:#000;border:none;border-radius:8px;padding:10px 20px;font-size:14px;font-weight:600;cursor:pointer;white-space:nowrap}
footer button:hover{background:var(--accent-hover)}
footer button:disabled{opacity:.5;cursor:not-allowed}
</style>
</head>
<body>
<header>
  <h1>&#x1F4E1; WeRSS Chat</h1>
  <span id="status">基于已订阅公众号的最新文章问答</span>
  <button id="logout" onclick="logout()">退出</button>
</header>
<main id="chat"></main>
<footer>
  <input id="question" placeholder="问关于已订阅公众号文章的问题..." autocomplete="off" onkeydown="if(event.key==='Enter')ask()">
  <button id="askBtn" onclick="ask()">发送</button>
</footer>
<script>
const chat=document.getElementById('chat'),questionEl=document.getElementById('question'),
      askBtn=document.getElementById('askBtn');

async function logout(){await fetch('/chat/logout',{method:'POST'});location.href='/chat';}

function addMsg(role,text,isError){
  const d=document.createElement('div');d.className='msg '+role+(isError?' error':'');
  const meta=document.createElement('div');meta.className='meta';
  meta.textContent=role==='user'?'你':role==='assistant'?'WeRSS':'错误';
  d.appendChild(meta);d.appendChild(document.createTextNode(text));chat.appendChild(d);
  chat.scrollTop=chat.scrollHeight;return d;}

async function ask(){
  const q=questionEl.value.trim();if(!q)return;
  questionEl.value='';askBtn.disabled=true;
  addMsg('user',q);
  const div=addMsg('assistant','');
  try{
    const resp=await fetch('/chat/ask',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({question:q})});
    if(resp.status===401){location.href='/chat';return;}
    if(!resp.ok){const t=await resp.text();div.classList.add('error');div.childNodes[1].textContent='请求失败: '+t;askBtn.disabled=false;return;}
    const reader=resp.body.getReader(),decoder=new TextDecoder();
    let buffer='',text='';
    while(true){
      const{done,value}=await reader.read();if(done)break;
      buffer+=decoder.decode(value,{stream:true});
      const lines=buffer.split('\n');buffer=lines.pop()||'';
      for(const line of lines){
        if(!line.startsWith('data: '))continue;
        const data=line.slice(6);
        if(data==='[DONE]')continue;
        try{const j=JSON.parse(data);
          if(j.error){div.classList.add('error');text+='\n[错误] '+j.error;continue;}
          const c=j.choices?.[0]?.delta?.content||'';text+=c;}
        catch(e){continue;}
      }
      div.childNodes[1].textContent=text;chat.scrollTop=chat.scrollHeight;
    }
  }catch(e){div.classList.add('error');div.childNodes[1].textContent='连接失败: '+e.message;}
  askBtn.disabled=false;
}
</script></body></html>"""


@app.get("/chat", response_class=HTMLResponse)
async def chat_page(request: Request):
    _, s = _session(request)
    return CHAT_HTML if s else LOGIN_HTML


@app.post("/chat/login")
async def login(username: str = Form(...), password: str = Form(...)):
    async with httpx.AsyncClient(timeout=15.0) as client:
        try:
            resp = await client.post(
                f"{WERSS_BASE}/api/v1/wx/auth/login",
                data={"username": username, "password": password},
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
        except Exception as e:
            return JSONResponse({"detail": f"无法连接 WeRSS: {e}"}, status_code=502)
    if resp.status_code != 200:
        return JSONResponse({"detail": "用户名或密码错误"}, status_code=401)
    data = resp.json()["data"]
    sid = secrets.token_urlsafe(32)
    SESSIONS[sid] = {
        "token": data["access_token"],
        "expires": time.time() + float(data.get("expires_in", 86400)),
    }
    out = JSONResponse({"ok": True})
    out.set_cookie(COOKIE, sid, max_age=86400 * 7, httponly=True, samesite="lax", path="/chat")
    return out


@app.post("/chat/logout")
async def logout(request: Request):
    sid, _ = _session(request)
    if sid:
        SESSIONS.pop(sid, None)
    out = JSONResponse({"ok": True})
    out.delete_cookie(COOKIE, path="/chat")
    return out


async def _build_context(client: httpx.AsyncClient, token: str) -> str:
    """Fetch recent subscribed articles and build a grounding context string."""
    headers = {"Authorization": f"Bearer {token}"}
    art_resp = await client.get(
        f"{WERSS_BASE}/api/v1/wx/articles",
        headers=headers,
        params={"limit": 15, "offset": 0},
    )
    art_resp.raise_for_status()
    articles = _list(art_resp.json())

    parts = []
    for i, a in enumerate(articles[:15]):
        if not isinstance(a, dict):
            continue
        title = a.get("title", "无标题")
        mp = a.get("mp_name", "")
        body = _strip_html(a.get("description", ""))
        # Enrich the first few with full article content (list view has no content).
        if i < 6 and a.get("id"):
            try:
                full = await client.get(
                    f"{WERSS_BASE}/api/v1/wx/articles/{a['id']}", headers=headers
                )
                full.raise_for_status()
                fd = full.json().get("data", {})
                content = _strip_html(fd.get("content", "")) if isinstance(fd, dict) else ""
                if content:
                    body = content[:1500]
            except Exception as e:
                log.warning(f"full content fetch failed for {a.get('id')}: {e}")
        parts.append(f"【{title}】（{mp}）\n{body[:1500]}")

    return "\n\n---\n\n".join(parts)


@app.post("/chat/ask")
async def ask(request: Request):
    _, s = _session(request)
    if not s:
        return JSONResponse({"detail": "未登录"}, status_code=401)

    data = await request.json()
    question = data["question"]

    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            context = await _build_context(client, s["token"])
        except Exception as e:
            log.warning(f"Failed to build context: {e}")
            context = ""

    if not context:
        context = "未找到相关文章。请确认 WeRSS 已订阅公众号且已抓取到文章。"

    async def generate():
        async with httpx.AsyncClient(timeout=120.0) as client:
            try:
                async with client.stream(
                    "POST",
                    DEEPSEEK_URL,
                    headers={
                        "Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "model": "deepseek-chat",
                        "messages": [
                            {
                                "role": "system",
                                "content": (
                                    "你是一个微信公众号文章研究助手。以下是用户已订阅公众号中的最近文章作为参考：\n\n"
                                    f"{context}\n\n"
                                    "请基于以上文章内容回答用户问题。如果文章中有相关信息，引用具体文章。"
                                    "如果没有相关信息，诚实说明'当前文章中没有相关内容'，不要编造。"
                                    "回答使用中文，简洁清晰。"
                                ),
                            },
                            {"role": "user", "content": question},
                        ],
                        "stream": True,
                        "temperature": 0.7,
                        "max_tokens": 2000,
                    },
                ) as resp:
                    if resp.status_code != 200:
                        body = await resp.aread()
                        yield f"data: {json.dumps({'error': f'DeepSeek API {resp.status_code}: {body.decode()[:200]}'})}\n\n"
                        return
                    async for line in resp.aiter_lines():
                        if line.startswith("data: "):
                            yield f"{line}\n\n"
            except Exception as e:
                log.error(f"DeepSeek error: {e}")
                yield f"data: {json.dumps({'error': str(e)})}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/health")
async def health():
    return {"status": "ok"}
