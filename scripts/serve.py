#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地自测：生成配置并启动一个静态文件服务器，方便在电脑上验证。
用法：
    python scripts/serve.py
然后浏览器打开 http://127.0.0.1:8899/dist/config.json
"""

import http.server
import os
import socketserver
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print(f"本地预览: http://127.0.0.1:{PORT}/dist/config.json")
        print("Ctrl+C 退出")
        httpd.serve_forever()
