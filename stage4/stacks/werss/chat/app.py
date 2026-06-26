import os, json, logging
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse
import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("chat")
app = FastAPI()

WERSS_BASE = "http://werss_server:8001"
DEEPSEEK_URL = "https://api.deepseek.com/v1/chat/completions"

HTML = r"""<!DOCTYPE html>
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
header input{flex:1;max-width:480px;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:8px 12px;color:var(--text);font-size:13px;outline:none}
header input:focus{border-color:var(--accent)}
header button{background:var(--accent);color:#000;border:none;border-radius:8px;padding:8px 16px;font-size:13px;font-weight:600;cursor:pointer}
header button:hover{background:var(--accent-hover)}
#status{font-size:12px;color:var(--muted)}
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
@keyframes blink{50%{opacity:.3}}
.streaming .dot{animation:blink 1s infinite}
.streaming .dot:nth-child(2){animation-delay:.2s}
.streaming .dot:nth-child(3){animation-delay:.4s}
</style>
</head>
<body>
<header>
  <h1>&#x1F4E1; WeRSS Chat</h1>
  <input id="key" type="password" placeholder="输入 WeRSS Access Key" autocomplete="off">
  <button onclick="saveKey()">保存</button>
  <span id="status"></span>
</header>
<main id="chat"></main>
<footer>
  <input id="question" placeholder="问关于已订阅公众号文章的问题..." autocomplete="off" onkeydown="if(event.key==='Enter')ask()">
  <button id="askBtn" onclick="ask()">发送</button>
</footer>
<script>
const chat=document.getElementById('chat'),keyEl=document.getElementById('key'),
      questionEl=document.getElementById('question'),askBtn=document.getElementById('askBtn'),
      statusEl=document.getElementById('status');
let accessKey=localStorage.getItem('werss_access_key')||'';
keyEl.value=accessKey;
if(accessKey)statusEl.textContent='✔ Key 已保存';
else statusEl.textContent='⚠ 请先输入 Key';

function saveKey(){accessKey=keyEl.value.trim();localStorage.setItem('werss_access_key',accessKey);
  statusEl.textContent=accessKey?'✔ Key 已保存':'⚠ 请先输入 Key';}

function addMsg(role,text,isError){
  const d=document.createElement('div');d.className='msg '+role+(isError?' error':'');
  const meta=document.createElement('div');meta.className='meta';
  meta.textContent=role==='user'?'你':role==='assistant'?'WeRSS':'错误';
  d.appendChild(meta);d.appendChild(document.createTextNode(text));chat.appendChild(d);
  chat.scrollTop=chat.scrollHeight;return d;}

async function ask(){
  const q=questionEl.value.trim();if(!q)return;if(!accessKey){alert('请先输入并保存 Access Key');return;}
  questionEl.value='';askBtn.disabled=true;
  addMsg('user',q);
  const div=addMsg('assistant','','','');
  try{
    const resp=await fetch('/chat/ask',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({question:q,access_key:accessKey})});
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
        try{const j=JSON.parse(data);const c=j.choices?.[0]?.delta?.content||'';text+=c;}
        catch(e){continue;}
      }
      div.childNodes[1].textContent=text;chat.scrollTop=chat.scrollHeight;
    }
  }catch(e){div.classList.add('error');div.childNodes[1].textContent='连接失败: '+e.message;}
  askBtn.disabled=false;
}
</script></body></html>"""


@app.get("/chat", response_class=HTMLResponse)
async def chat_page():
    return HTML


@app.post("/chat/ask")
async def ask(request: Request):
    data = await request.json()
    question = data["question"]
    access_key = data["access_key"]

    headers = {"Authorization": f"Bearer {access_key}"}
    articles = []

    async with httpx.AsyncClient(timeout=30.0) as client:
        # 1. get subscriptions
        try:
            subs_resp = await client.get(f"{WERSS_BASE}/api/v1/subscriptions", headers=headers)
            subs_resp.raise_for_status()
            subs = subs_resp.json()
            mp_list = subs if isinstance(subs, list) else subs.get("items", subs.get("data", []))
            if isinstance(mp_list, dict):
                mp_list = list(mp_list.values())
        except Exception as e:
            log.warning(f"Failed to get subscriptions: {e}")
            mp_list = []

        if not mp_list:
            # Try direct article list without filtering
            try:
                art_resp = await client.get(f"{WERSS_BASE}/api/v1/articles", headers=headers, params={"limit": 20})
                art_resp.raise_for_status()
                data = art_resp.json()
                articles = data if isinstance(data, list) else data.get("items", data.get("data", []))
                if isinstance(articles, dict):
                    articles = list(articles.values())
            except Exception as e:
                log.warning(f"Failed to get articles: {e}")

        # 2. get articles from each subscription (up to 3 subs)
        for sub in mp_list[:3]:
            mp_name = sub.get("mp_name", sub.get("name", "")) if isinstance(sub, dict) else str(sub)
            try:
                art_resp = await client.get(
                    f"{WERSS_BASE}/api/v1/articles",
                    headers=headers,
                    params={"mp_name": mp_name, "limit": 5}
                )
                art_resp.raise_for_status()
                data = art_resp.json()
                items = data if isinstance(data, list) else data.get("items", data.get("data", []))
                if isinstance(items, dict):
                    items = list(items.values())
                articles.extend(items)
            except Exception as e:
                log.warning(f"Failed to get articles for {mp_name}: {e}")

    # Build context
    context_parts = []
    for a in articles[:15]:
        title = a.get("title", a.get("name", "无标题")) if isinstance(a, dict) else str(a)
        content = ""
        if isinstance(a, dict):
            content = a.get("content", a.get("summary", a.get("description", "")))
        context_parts.append(f"【{title}】\n{content[:1000]}")
    context = "\n\n---\n\n".join(context_parts)

    if not context:
        context = "未找到相关文章。请确认已订阅公众号且Access Key有效。"

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
