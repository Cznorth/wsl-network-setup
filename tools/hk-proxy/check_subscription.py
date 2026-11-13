#!/usr/bin/env python3
"""只读检查香港聚合订阅；订阅地址从私密文件读取，避免进入命令行或日志。"""
import argparse
import json
import pathlib
import sys
import urllib.request

import yaml


def audit(document, baseline=None, expected=4):
    if not isinstance(document, dict):
        raise ValueError("订阅不是 YAML mapping")
    nodes = document.get("proxies", [])
    names = [node["name"] for node in nodes]
    if len(names) != len(set(names)):
        raise ValueError("订阅包含重名节点")
    added = [node for node in nodes if node["name"].startswith("香港-hkv4")]
    if len(added) != expected:
        raise ValueError("香港节点数量不符合预期")
    for node in added:
        if not (node.get("type") == "vless" and node.get("tls") is True
                and node.get("flow") == "xtls-rprx-vision"
                and node.get("client-fingerprint") == "chrome"
                and node.get("reality-opts", {}).get("support-x25519mlkem768") is True):
            raise ValueError("REALITY / Vision / ML-KEM 配置不完整")
    if baseline is not None:
        if document.get("rules") != baseline.get("rules"):
            raise ValueError("原有规则发生变化")
        if not all(group in document.get("proxy-groups", []) for group in baseline.get("proxy-groups", [])):
            raise ValueError("原有策略组发生变化")
        if not all(node in nodes for node in baseline.get("proxies", [])):
            raise ValueError("原有静态节点缺失或发生变化")
    return {"total_nodes": len(nodes), "hong_kong_nodes": len(added), "names": [n["name"] for n in added]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url-file", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--expected", type=int, default=4)
    args = parser.parse_args()
    try:
        url = args.url_file.read_text(encoding="utf-8").strip()
        if not url.startswith("https://"):
            raise ValueError("订阅必须使用 HTTPS")
        with urllib.request.urlopen(url, timeout=90) as response:
            document = yaml.safe_load(response.read())
            status = response.status
        baseline = yaml.safe_load(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
        result = audit(document, baseline, args.expected)
        result["http"] = status
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as error:
        # 网络异常的 message 可能携带完整的私密订阅地址，不能直接输出。
        print("audit_failed: " + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
