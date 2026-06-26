#!/usr/bin/env python3
"""
CC-Loop Search MCP Server v4
- 底层走 stepfun 套餐 StepSearch MCP 通道（step_plan/v1/mcp）真联网检索，消耗套餐 Credit
- 检索结果再交 step-3.7-flash 做结构化整理（基于真实数据，不再脑补）
- 单工具 search，三个参数：query + category/focus(二选一) + follow_up
- category 映射到套餐搜索的场景（programming/research/gov/business），不再依赖 prompt 模板堆砌
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone, timedelta


# ---- 可配置项（全部读环境变量，密钥不写死在代码里）----
# 用 `or` 兜底：当环境变量被显式设为空字符串时也回退到默认值
# ⚠️ API Key 必须通过环境变量 SEARCH_API_KEY 提供，不设则搜索功能不可用
API_KEY = os.environ.get("SEARCH_API_KEY", "")
if not API_KEY:
    sys.stderr.write(
        "[search_mcp] 警告: 未设置环境变量 SEARCH_API_KEY，搜索功能将不可用。\n"
        "请在 stepfun 开放平台获取 API Key 后: export SEARCH_API_KEY=your_key\n"
    )
# 真联网检索：走套餐 MCP 通道（消耗 Step Plan 月度 Credit，与套餐搜索次数统一计费）
# 注意：不要用 https://api.stepfun.com/v1/search —— 那是标准付费接口，消耗充值余额而非套餐额度
SEARCH_MCP_URL = os.environ.get("SEARCH_MCP_URL", "") or \
    "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp"
# 结构化整理用的 LLM（走套餐端点，消耗 Step Plan Credit）
LLM_API_URL = os.environ.get("SEARCH_LLM_URL", "") or \
    "https://api.stepfun.com/step_plan/v1/chat/completions"
MODEL = os.environ.get("SEARCH_MODEL", "") or "step-3.7-flash"
MAX_INPUT_CHARS = 100000
SEARCH_N = 8  # 每次真联网检索返回的条数

BJ_TIME = timezone(timedelta(hours=8))


def get_now_str():
    now = datetime.now(BJ_TIME)
    return now.strftime("%Y年%m月%d日")


# category -> (stepfun 套餐搜索的 scene, query 修饰词)
# 套餐 MCP web_search 支持的 scene：programming / research / gov / business（留空=全场景）
CATEGORY_MAP = {
    "latest":     ("",             "最新进展 最新动态"),
    "papers":     ("research",     "学术论文 paper"),
    "projects":   ("programming",  "开源项目 github"),
    "articles":   ("",             "技术文章 博客 实践"),
    "pitfalls":   ("",             "已知问题 bug 漏洞 踩坑"),
    "comparison": ("",             "对比 选型 benchmark"),
    "tutorial":   ("programming",  "教程 用法 示例 文档"),
    "spec":       ("",             "标准 规范 RFC"),
    "general":    ("",             ""),
}


def _mcp_call(name, arguments, timeout=60):
    """调用套餐远程 MCP 的 tools/call，返回 content[0].text 解析后的 dict。"""
    payload = {
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        SEARCH_MCP_URL, data=data,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {API_KEY}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    obj = json.loads(raw)
    # MCP 返回结构：result.content[0].text（内层是 JSON 字符串）
    text = obj["result"]["content"][0]["text"]
    return json.loads(text)


def _post_json(url, payload, timeout=90):
    """发送 JSON POST，返回解析后的 dict；失败抛异常。"""
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {API_KEY}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def web_search(query, scene=""):
    """调套餐 MCP 通道的 web_search 真联网检索，返回原始结果列表。

    scene 为 stepfun 搜索场景：programming / research / gov / business，
    空串表示不限定（全场景搜索）。
    """
    args = {"query": query, "n": SEARCH_N}
    if scene:
        args["category"] = scene
    data = _mcp_call("web_search", args, timeout=60)
    return data.get("results", []) or []


def web_fetch(url):
    """调套餐 MCP 的 web_fetch 抓取指定 URL 正文（免费，不单独计费）。"""
    return _mcp_call("web_fetch", {"url": url}, timeout=60)


def llm_summarize(query, mode_hint, results):
    """让 LLM 基于真实搜索结果做结构化整理。绝不凭空编造——无结果时直接返回。"""
    if not results:
        return "(未检索到相关结果)"

    # 把真实结果喂给 LLM，要求只基于这些整理
    # 套餐 MCP 的 web_search 返回 snippet + content（网页正文），信息更全
    sources_block = "\n\n".join(
        f"[{i}] {r.get('title', '')}\n"
        f"URL: {r.get('url', '')}\n"
        f"时间: {r.get('time', '未知')}\n"
        f"摘要: {(r.get('snippet') or '').strip()}\n"
        f"正文: {(r.get('content') or '')[:800].strip()}"
        for i, r in enumerate(results, 1)
    )

    prompt = (
        f"以下是关于「{query}」的真实联网检索结果（已按{mode_hint}方向检索）。\n"
        f"请只基于下面这些真实结果整理，**不要编造任何不在结果中的 URL 或事实**。\n"
        f"如果结果不足以回答，直接说明信息不足。\n\n"
        f"---检索结果---\n{sources_block}\n---结束---\n\n"
        f"输出格式：编号列表，每条包含：标题、URL、发布时间、一句话摘要、与本主题的相关性。"
        f"按相关性从高到低排序，过滤掉明显无关的条目。"
    )

    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 4000,
        "temperature": 0.2,
    }
    try:
        data = _post_json(LLM_API_URL, payload, timeout=90)
        return (data.get("choices", [{}])[0]
                .get("message", {}).get("content", "(整理失败)")
                .strip() or "(整理失败)")
    except Exception as e:
        # LLM 整理失败时降级：直接返回原始结果，绝不退回脑补
        return f"(LLM 整理失败: {e}，以下为原始检索结果)\n\n{sources_block}"


def do_search(query, category="general", focus="", follow_up=""):
    """主入口：真联网检索 + LLM 结构化整理。

    三种模式（优先级 follow_up > focus > category）：
    - follow_up：把追问词作为更聚焦的搜索词，深入搜某个具体点
    - focus：按自由描述的角度检索
    - category：按固定角度检索（映射到搜索场景）
    """
    if len(query) > MAX_INPUT_CHARS:
        query = query[:MAX_INPUT_CHARS] + "\n...(已截断)"

    # 1. 构造真实检索词与场景
    if follow_up:
        search_term = follow_up  # 追问通常自带具体实体，直接作为检索词
        scene = ""
        mode_hint = "追问/深入"
    elif focus:
        search_term = focus       # 自由角度作为主检索词
        scene = ""
        mode_hint = f"角度={focus}"
    else:
        scene, modifier = CATEGORY_MAP.get(category, CATEGORY_MAP["general"])
        search_term = f"{query} {modifier}".strip() if modifier else query
        mode_hint = f"角度={category}"

    # 2. 真联网检索
    try:
        results = web_search(search_term, scene=scene)
    except Exception as e:
        return f"(联网检索失败: {e})"

    # 3. LLM 结构化整理（基于真实结果）
    date_str = get_now_str()
    summary = llm_summarize(query, mode_hint, results)

    header = (
        f"## 搜索结果（{date_str} · 真联网检索 {len(results)} 条 · {mode_hint}）\n"
        f"检索词：{search_term}\n\n"
    )
    return header + summary


def handle_request(req):
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "cc-loop-search", "version": "4.0.0"},
            },
        }

    if method == "tools/list":
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "tools": [{
                    "name": "search",
                    "description": (
                        "联网搜索外部资料（真实检索，非模型记忆）。"
                        "返回带真实 URL 和发布时间的结构化结果。\n"
                        "三种用法：\n"
                        "1. category：固定角度（latest/papers/projects/articles/"
                        "pitfalls/comparison/tutorial/spec/general）\n"
                        "2. focus：自由描述检索角度，比 category 更灵活\n"
                        "3. follow_up：针对某个具体点换更聚焦的词再搜一次\n"
                        "建议：对同一主题从多个角度调用以全面覆盖。"
                    ),
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "搜索主题（自然语言）",
                            },
                            "category": {
                                "type": "string",
                                "enum": ["latest", "papers", "projects", "articles",
                                         "pitfalls", "comparison", "tutorial", "spec", "general"],
                                "default": "general",
                                "description": "固定搜索角度（与 focus 二选一）",
                            },
                            "focus": {
                                "type": "string",
                                "description": "自由描述检索角度（自然语言），覆盖 category",
                            },
                            "follow_up": {
                                "type": "string",
                                "description": "更聚焦的检索词，深入搜某个具体点",
                            },
                        },
                        "required": ["query"],
                    },
                }]
            },
        }

    if method == "tools/call":
        tool_name = params.get("name", "")
        args = params.get("arguments", {})
        if tool_name == "search":
            query = args.get("query", "")
            category = args.get("category", "general")
            focus = args.get("focus", "")
            follow_up = args.get("follow_up", "")
            result = do_search(query, category, focus, follow_up)
            return {
                "jsonrpc": "2.0", "id": req_id,
                "result": {"content": [{"type": "text", "text": result}]},
            }
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {"content": [{"type": "text", "text": f"未知工具: {tool_name}"}]},
        }

    if req_id is None:
        return None

    return {
        "jsonrpc": "2.0", "id": req_id,
        "error": {"code": -32601, "message": f"未知方法: {method}"},
    }


def run_once():
    """命令行入口: python search_mcp.py --once <query> [category] [focus]
    供 utils.sh 的 run_search 直接调用,与 MCP 工具共用 do_search。"""
    args = sys.argv[2:]  # 跳过 --once
    query = args[0] if len(args) > 0 else ""
    category = args[1] if len(args) > 1 and args[1] else "general"
    focus = args[2] if len(args) > 2 else ""
    if not query:
        print("(错误: 缺少 query 参数)")
        sys.exit(1)
    print(do_search(query, category=category, focus=focus))


def main():
    # 命令行直调模式(供 bash run_search 使用),与 MCP 协议模式共用 do_search
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        run_once()
        return
    # MCP stdio 协议模式
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle_request(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
