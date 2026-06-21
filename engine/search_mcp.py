#!/usr/bin/env python3
"""
CC-Loop Search MCP Server v3
- 固定基础角度（latest/papers/projects）+ 自由角度（focus）+ 追问（follow_up）
- 每次注入当前日期
- 单工具，三个参数：query + focus(可选) + follow_up(可选)
"""
import json
import sys
import urllib.request
from datetime import datetime, timezone, timedelta


API_URL = "https://api.stepfun.com/step_plan/v1/chat/completions"
API_KEY = "Jh9uEG2u3K5U4KEJq2CsRNw0dfobIhWaQ65GxrAiynIP21GsLXYjeENJb2aqhOi8"
MODEL = "step-3.7-flash"
MAX_INPUT_CHARS = 100000

BJ_TIME = timezone(timedelta(hours=8))


def get_now_str():
    now = datetime.now(BJ_TIME)
    return now.strftime("%Y年%m月%d日")


# 固定基础角度的 prompt 模板
CATEGORY_TEMPLATES = {
    "latest": (
        "当前日期：{date}。\n"
        "搜索以下主题的**最新进展**（2025-2026年），重点关注最近几个月。\n"
        "标注每个结果的时效性（最新/较新/过时）。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：标题、URL、发布日期、一句话摘要、时效性。"
    ),
    "papers": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**学术论文**（优先 arxiv、NeurIPS/ICML/ACL/SIGIR/KDD）。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：论文标题、URL、作者/机构、发表年份/会议、核心方法、相关性。"
    ),
    "projects": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**开源项目**（GitHub），关注活跃维护、star高、文档完善的。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每个：名称、URL、star数、语言、最后更新、核心功能、适用场景。"
    ),
    "articles": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**技术文章/博客/实践指南**，关注落地经验和踩坑。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：标题、URL、来源、摘要、实操价值。"
    ),
    "pitfalls": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**已知问题、陷阱、安全漏洞、废弃警告**。\n"
        "关注：CVE、已知 bug、stack overflow 高赞问题、框架废弃通告、常见踩坑。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：问题标题、URL、严重程度、影响范围、一句话描述。"
    ),
    "comparison": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**对比分析、选型指南、benchmark**。\n"
        "关注：X vs Y 的优劣对比、不同方案的适用场景、性能基准测试。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：对比维度、结论、URL、数据来源。"
    ),
    "tutorial": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**教程、API 文档、用法示例**。\n"
        "关注：quickstart、具体 API 调用方式、代码示例、配置方法。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：标题、URL、类型(教程/文档/示例)、核心内容摘要。"
    ),
    "spec": (
        "当前日期：{date}。\n"
        "搜索以下主题相关的**标准、规范、RFC、设计原则**。\n"
        "关注：官方规范、RFC、语言标准、框架设计约定。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：标准/规范名称、URL、版本、核心约定摘要。"
    ),
    "general": (
        "当前日期：{date}。\n"
        "搜索以下主题，整理所有相关结果。\n\n"
        "主题：{query}\n\n"
        "整理成列表，每条：标题、URL、摘要、相关性。"
    ),
}


def call_step_api(query: str, category: str = "general",
                  focus: str = "", follow_up: str = "") -> str:
    """调用 step-3.7-flash API。支持 category（固定角度）或 focus（自由角度）或 follow_up（追问）。"""
    if len(query) > MAX_INPUT_CHARS:
        query = query[:MAX_INPUT_CHARS] + "\n...(已截断)"

    date_str = get_now_str()

    # 三种模式：follow_up 优先 > focus > category
    if follow_up:
        prompt_text = (
            f"当前日期：{date_str}。\n"
            f"基于之前的搜索结果，深入搜索以下具体内容：\n\n"
            f"追问主题：{follow_up}\n"
            f"（原始主题：{query}）\n\n"
            f"给出详细信息：具体方法、实现细节、数据、代码示例等。"
        )
    elif focus:
        prompt_text = (
            f"当前日期：{date_str}。\n"
            f"从以下角度搜索：{focus}\n\n"
            f"主题：{query}\n\n"
            f"按这个角度整理结果，每条：标题、URL、摘要、与角度的相关性。"
        )
    else:
        template = CATEGORY_TEMPLATES.get(category, CATEGORY_TEMPLATES["general"])
        prompt_text = template.format(date=date_str, query=query)

    payload = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": 8000,
        "temperature": 0.3,
    }).encode("utf-8")

    req = urllib.request.Request(
        API_URL, data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("choices", [{}])[0].get("message", {}).get("content", "(无内容)")
    except Exception as e:
        return f"(搜索失败: {e})"


def handle_request(req: dict) -> dict:
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "cc-loop-search", "version": "3.0.0"},
            },
        }

    if method == "tools/list":
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "tools": [{
                    "name": "search",
                    "description": (
                        "搜索外部资料。每次自动注入当前日期。\n"
                        "三种用法：\n"
                        "1. category：用固定角度搜（latest/papers/projects/articles/pitfalls/comparison/tutorial/spec/general）\n"
                        "2. focus：自由描述搜索角度（如'BM25和向量检索的性能对比'），比 category 更灵活\n"
                        "3. follow_up：基于之前结果追问某个具体条目的详情（如'详细搜刚才那篇RRF论文的算法'）\n"
                        "建议：对同一主题，从多个角度/多次调用，获得全面覆盖。"
                        "看到有价值的结果可以继续追问深入。"
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
                                "description": "自由描述搜索角度（自然语言），覆盖 category",
                            },
                            "follow_up": {
                                "type": "string",
                                "description": "基于之前搜索结果的追问关键词，深入搜某个具体条目",
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
            result = call_step_api(query, category, focus, follow_up)
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


def main():
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
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
